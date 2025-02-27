param(
    [Parameter(Mandatory = $true, HelpMessage = "Enter SHM ID (e.g. use 'testa' for Turing Development Safe Haven A)")]
    [string]$shmId,
    [Parameter(Mandatory = $true, HelpMessage = "Enter SRE ID (e.g. use 'sandbox' for Turing Development Sandbox SREs)")]
    [string]$sreId
)

Import-Module $PSScriptRoot/../../common/AzureDataProtection -Force -ErrorAction Stop
Import-Module $PSScriptRoot/../../common/AzureResources -Force -ErrorAction Stop
Import-Module $PSScriptRoot/../../common/Configuration -Force -ErrorAction Stop
Import-Module $PSScriptRoot/../../common/Logging -Force -ErrorAction Stop

# Get config and original context before changing subscription
# ------------------------------------------------------------
$config = Get-SreConfig -shmId $shmId -sreId $sreId
$originalContext = Get-AzContext
$null = Set-AzContext -SubscriptionId $config.sre.subscriptionName -ErrorAction Stop


# Deploy backup resource group
# ----------------------------
$null = Deploy-ResourceGroup -Name $config.sre.backup.rg -Location $config.shm.location


# Register DataProtection provider
# --------------------------------
$RegistrationState = (Get-AzResourceProvider | Where-Object { $_.ProviderNamespace -eq “Microsoft.DataProtection” }).RegistrationState
while ($RegistrationState -ne "Registered") {
    if ($RegistrationState -ne "Registering") {
        $null = Register-AzResourceProvider -ProviderNamespace Microsoft.DataProtection
    } else {
        Start-Sleep 30
    }
}


# Deploy data protection backup vault
# -----------------------------------
$Vault = Deploy-DataProtectionBackupVault -ResourceGroupName $config.sre.backup.rg `
                                          -VaultName $config.sre.backup.vault.name `
                                          -Location $config.sre.location


# Create blob backup policy
# This enforces the default policy for blobs
# ------------------------------------------
$Policy = Deploy-DataProtectionBackupPolicy -ResourceGroupName $config.sre.backup.rg `
                                            -VaultName $config.sre.backup.vault.name `
                                            -PolicyName $config.sre.backup.blob.policy_name `
                                            -DataSourceType 'blob'


# Get persistent storage account in the SHM
# -----------------------------------------
$null = Set-AzContext -SubscriptionId $config.shm.subscriptionName -ErrorAction Stop
$PersistentStorageAccount = Get-AzStorageAccount -ResourceGroupName $config.shm.storage.persistentdata.rg -Name $config.sre.storage.persistentdata.account.name
$null = Set-AzContext -SubscriptionId $config.sre.subscriptionName -ErrorAction Stop


# Assign permissions required for blob backup to the Vault's managed identity
# ---------------------------------------------------------------------------
$null = Deploy-RoleAssignment -ObjectId $Vault.IdentityPrincipalId `
                              -Scope $PersistentStorageAccount.id `
                              -RoleDefinitionName "Storage Account Backup Contributor"


# Create blob backup instance
# ---------------------------
$null = Deploy-DataProtectionBackupInstance -BackupPolicyId $Policy.Id `
                                            -ResourceGroupName $config.sre.backup.rg `
                                            -VaultName $Vault.Name `
                                            -DataSourceType 'blob' `
                                            -DataSourceId $PersistentStorageAccount.Id `
                                            -DataSourceLocation $PersistentStorageAccount.PrimaryLocation `
                                            -DataSourceName $PersistentStorageAccount.StorageAccountName


# Create disk backup policy
# This enforces the default policy for disks
# ------------------------------------------
$Policy = Deploy-DataProtectionBackupPolicy -ResourceGroupName $config.sre.backup.rg `
                                            -VaultName $config.sre.backup.vault.name `
                                            -PolicyName $config.sre.backup.disk.policy_name `
                                            -DataSourceType 'disk'


# Assign permissions required for disk backup
# Permission to create snapshots in backup resource group
# -------------------------------------------------------
$null = Deploy-RoleAssignment -ObjectId $Vault.IdentityPrincipalId `
                              -ResourceGroupName $config.sre.backup.rg `
                              -RoleDefinitionName "Disk Snapshot Contributor"
$selected_rgs = @(
    $config.sre.databases.rg
    $config.sre.webapps.rg
)
foreach ($rg in $selected_rgs) {
    # Permission to create snapshots from disks in relevant resource groups
    $null = Deploy-RoleAssignment -ObjectId $Vault.IdentityPrincipalId `
                                  -ResourceGroupName $rg `
                                  -RoleDefinitionName "Disk Backup Reader"

    # Permission to create new disks (restore points) in relevant resource groups
    $null = Deploy-RoleAssignment -ObjectId $Vault.IdentityPrincipalId `
                                  -ResourceGroupName $rg `
                                  -RoleDefinitionName "Disk Restore Operator"
}
Start-Sleep 30 # Allow time for role assignments to persist


# Create backup instances for all disks in selected resource groups
# -----------------------------------------------------------------
$selected_disks = Get-AzDisk | Where-Object { $_.ResourceGroupName -in $selected_rgs } | Where-Object { $_.Name -like "*DATA-DISK" }
foreach ($disk in $selected_disks) {
    $null = Deploy-DataProtectionBackupInstance -BackupPolicyId $Policy.Id `
                                                -ResourceGroupName $config.sre.backup.rg `
                                                -VaultName $Vault.Name `
                                                -DataSourceType 'disk' `
                                                -DataSourceId $disk.Id `
                                                -DataSourceLocation $disk.Location `
                                                -DataSourceName $disk.Name
}


# Switch back to original subscription
# ------------------------------------
$null = Set-AzContext -Context $originalContext -ErrorAction Stop
