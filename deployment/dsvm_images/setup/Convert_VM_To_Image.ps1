param(
    [Parameter(Mandatory = $true, HelpMessage = "Enter SHM ID (usually a string e.g enter 'testa' for Turing Development Safe Haven A)")]
    [string]$shmId,
    [Parameter(Mandatory = $true, HelpMessage = "Specify a machine name to turn into an image. Ensure that the build script has completely finished before running this")]
    [string]$vmName
)

Import-Module Az -ErrorAction Stop
Import-Module $PSScriptRoot/../../common/Configuration -Force -ErrorAction Stop
Import-Module $PSScriptRoot/../../common/Deployments -Force -ErrorAction Stop
Import-Module $PSScriptRoot/../../common/Logging -Force -ErrorAction Stop
Import-Module $PSScriptRoot/../../common/Security -Force -ErrorAction Stop


# Get config and original context before changing subscription
# ------------------------------------------------------------
$config = Get-ShmConfig -shmId $shmId
$originalContext = Get-AzContext
$null = Set-AzContext -SubscriptionId $config.dsvmImage.subscription -ErrorAction Stop


# Construct build VM parameters
# -----------------------------
$buildVmAdminUsername = Resolve-KeyVaultSecret -VaultName $config.dsvmImage.keyVault.name -SecretName $config.keyVault.secretNames.buildImageAdminUsername -DefaultValue "dsvmbuildadmin" -AsPlaintext


# Setup image resource group if it does not already exist
# -------------------------------------------------------
$null = Deploy-ResourceGroup -Name $config.dsvmImage.images.rg -Location $config.dsvmImage.location


# Look for this VM in the appropriate resource group
# --------------------------------------------------
$vm = Get-AzVM -Name $vmName -ResourceGroupName $config.dsvmImage.build.rg -ErrorVariable notExists -ErrorAction SilentlyContinue
if ($notExists) {
    Add-LogMessage -Level Error "Could not find a machine called '$vmName' in resource group $($config.dsvmImage.build.rg)"
    Add-LogMessage -Level Info "Available machines are:"
    foreach ($candidateVM in Get-AzVM -ResourceGroupName $config.dsvmImage.build.rg) {
        Add-LogMessage -Level Info "  $($candidateVM.Name)"
    }
    Add-LogMessage -Level Fatal "Could not find a machine called '$vmName'!"
}


# Ensure that the VM is running
# -----------------------------
Start-VM -Name $vmName -ResourceGroupName $config.dsvmImage.build.rg
Start-Sleep 60  # Wait to ensure that SSH is able to accept connections


# Check the VM build status and ask for user confirmation
# -------------------------------------------------------
Add-LogMessage -Level Info "Obtaining build status for candidate: $($vm.Name)..."
$null = Invoke-RemoteScript -VMName $vm.Name -ResourceGroupName $config.dsvmImage.build.rg -Shell "UnixShell" -Script "python3 /opt/monitoring/analyse_build.py"
Add-LogMessage -Level Info "Please check that the output of the build analysis script (above) before continuing. All steps should have completed with a 'SUCCESS' message."
$confirmation = Read-Host "Are you sure you want to deprovision '$($vm.Name)' and turn it into a VM image? [y/n]"
while ($confirmation -ne "y") {
    if ($confirmation -eq "n") { exit 0 }
    $confirmation = Read-Host "Are you sure you want to deprovision '$($vm.Name)' and turn it into a VM image? [y/n]"
}


# Deprovision the VM over SSH
# ---------------------------
Add-LogMessage -Level Info "Deprovisioning VM: $($vm.Name)..."
$adminPasswordName = "$($config.keyVault.secretNames.buildImageAdminPassword)-${vmName}"
$publicIp = (Get-AzPublicIpAddress -ResourceGroupName $config.dsvmImage.build.rg | Where-Object { $_.Id -Like "*$($vm.Name)-NIC-PIP" }).IpAddress
Add-LogMessage -Level Info "... preparing to send deprovisioning command over SSH to: $publicIp..."
Add-LogMessage -Level Info "... the password for this account is in the '${adminPasswordName}' secret in the '$($config.dsvmImage.keyVault.name)' Key Vault"
ssh -t ${buildVmAdminUsername}@${publicIp} 'sudo /opt/build/deprovision_vm.sh | sudo tee /opt/monitoring/deprovision.log'
if (-not $?) {
    Add-LogMessage -Level Fatal "Unable to send deprovisioning command!"
}

# Poll VM to see whether it has finished running
# ----------------------------------------------
Add-LogMessage -Level Info "Waiting for deprovisioning to finish..."
$progress = 0
$statuses = (Get-AzVM -Name $vm.Name -ResourceGroupName $config.dsvmImage.build.rg -Status).Statuses.Code
while (-not $statuses.Contains("ProvisioningState/succeeded")) {
    $statuses = (Get-AzVM -Name $vm.Name -ResourceGroupName $config.dsvmImage.build.rg -Status).Statuses.Code
    $progress = [math]::min(100, $progress + 1)
    Write-Progress -Activity "Deprovisioning status" -Status "$($statuses[0]) $($statuses[1])" -PercentComplete $progress
    Start-Sleep 10
}


# Deallocate and generalize. Commands in Powershell are different from the Azure CLI https://docs.microsoft.com/en-us/azure/virtual-machines/windows/tutorial-custom-images
# -------------------------------------------------------------------------------------------------------------------------------------------------------------------------
Add-LogMessage -Level Info "Deallocating and generalising VM: '$($vm.Name)'. This can take up to 20 minutes..."
$null = Stop-AzVM -ResourceGroupName $config.dsvmImage.build.rg -Name $vm.Name -Force
Add-LogMessage -Level Info "VM has been stopped"
$null = Set-AzVM -ResourceGroupName $config.dsvmImage.build.rg -Name $vm.Name -Generalized
Add-LogMessage -Level Info "VM has been generalized"


# Create an image from the deallocated VM
# ---------------------------------------
$imageName = "Image$($vm.Name -replace 'Candidate', '')"
$vm = Get-AzVM -Name $vm.Name -ResourceGroupName $config.dsvmImage.build.rg
$imageConfig = New-AzImageConfig -Location $config.dsvmImage.location -SourceVirtualMachineId $vm.ID
$image = New-AzImage -Image $imageConfig -ImageName $imageName -ResourceGroupName $config.dsvmImage.images.rg
# Apply VM tags to the image
$null = New-AzTag -ResourceId $image.Id -Tag @{"Build commit hash" = $vm.Tags["Build commit hash"] }
Add-LogMessage -Level Info "Finished creating image $imageName"
# If the image has been successfully created then remove build artifacts
if ($image) {
    Add-LogMessage -Level Info "Removing residual artifacts of the build process from $($config.dsvmImage.build.rg)..."
    Add-LogMessage -Level Info "... virtual machine: $vmName"
    $null = Remove-VirtualMachine -Name $vmName -ResourceGroupName $config.dsvmImage.build.rg -Force -ErrorAction SilentlyContinue
    Add-LogMessage -Level Info "... hard disk: ${vmName}-OS-DISK"
    $null = Remove-AzDisk -DiskName $vmName-OS-DISK -ResourceGroupName $config.dsvmImage.build.rg -Force -ErrorAction SilentlyContinue
    Add-LogMessage -Level Info "... network card: $vmName-NIC"
    $null = Remove-AzNetworkInterface -Name $vmName-NIC -ResourceGroupName $config.dsvmImage.build.rg -Force -ErrorAction SilentlyContinue
    Add-LogMessage -Level Info "... public IP address: ${vmName}-NIC-PIP"
    $null = Remove-AzPublicIpAddress -Name $vmName-NIC-PIP -ResourceGroupName $config.dsvmImage.build.rg -Force -ErrorAction SilentlyContinue
    Add-LogMessage -Level Info "... KeyVault password: ${adminPasswordName}"
    Remove-AndPurgeKeyVaultSecret -VaultName $config.dsvmImage.keyVault.name -SecretName $adminPasswordName
} else {
    Add-LogMessage -Level Fatal "Image '$imageName' could not be created!"
}


# Switch back to original subscription
# ------------------------------------
$null = Set-AzContext -Context $originalContext -ErrorAction Stop
