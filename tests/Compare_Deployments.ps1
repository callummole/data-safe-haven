# You will need `Install-Package Communary.PASM`
param(
    [Parameter(Mandatory = $true, HelpMessage = "Name of the current (working) subscription")]
    [string]$currentSubscription,
    [Parameter(Mandatory = $true, HelpMessage = "Name of the new (proposed) subscription")]
    [string]$newSubscription,
    [Parameter(Mandatory = $false, HelpMessage = "Print verbose logging messages")]
    [switch]$VerboseLogging = $false
)

Import-Module Az
Import-Module Communary.PASM
Import-Module $PSScriptRoot/../common_powershell/Logging.psm1 -Force

function Select-ClosestMatch {
    param (
        [Parameter(Position = 0)][ValidateNotNullOrEmpty()]
        [string] $Value,
        [Parameter(Position = 1)][ValidateNotNullOrEmpty()]
        [System.Array] $Array
    )
    $Array | Sort-Object @{Expression={ Get-PasmScore -String1 $Value -String2 $_ -Algorithm "LevenshteinDistance" }; Ascending=$false} | Select-Object -First 1
}


function Compare-NSGRules {
    param (
        [Parameter()]
        [System.Array] $CurrentRules,
        [Parameter()]
        [System.Array] $NewRules
    )
    $nMatched = 0
    $unmatched = @()
    foreach ($currentRule in $CurrentRules) {
        $lowestDifference = 99
        $closestMatchingRule = $null
        foreach ($newRule in $NewRules) {
            $difference = 0
            if ($currentRule.Protocol -ne $newRule.Protocol) { $difference += 1 }
            if ([string]($currentRule.SourcePortRange) -ne [string]($newRule.SourcePortRange)) { $difference += 1 }
            if ([string]($currentRule.DestinationPortRange) -ne [string]($newRule.DestinationPortRange)) { $difference += 1 }
            if ([string]($currentRule.SourceAddressPrefix) -ne [string]($newRule.SourceAddressPrefix)) { $difference += 1 }
            if ([string]($currentRule.DestinationAddressPrefix) -ne [string]($newRule.DestinationAddressPrefix)) { $difference += 1 }
            if ($currentRule.Access -ne $newRule.Access) { $difference += 1 }
            if ($currentRule.Priority -ne $newRule.Priority) { $difference += 1 }
            if ($currentRule.Direction -ne $newRule.Direction) { $difference += 1 }
            if ($difference -lt $lowestDifference) {
                $lowestDifference = $difference
                $closestMatchingRule = $newRule
            }
            if ($difference -eq 0) { break }
        }

        if ($lowestDifference -eq 0) {
            $nMatched += 1
            if ($VerboseLogging) { Add-LogMessage -Level Info "Found matching rule for $($currentRule.Name)" }
        } else {
            Add-LogMessage -Level Error "Could not find matching rule for $($currentRule.Name)"
            $unmatched += $currentRule.Name
            $currentRule | Out-String
            Add-LogMessage -Level Info "Closest match was:"
            $closestMatchingRule | Out-String
        }
    }

    $nTotal = $nMatched + $unmatched.Count
    if ($nMatched -eq $nTotal) {
        Add-LogMessage -Level Success "Matched $nMatched/$nTotal rules"
    } else {
        Add-LogMessage -Level Failure "Matched $nMatched/$nTotal rules"
    }
}


function Test-OutboundConnection {
    param (
        [Parameter(Position = 0)][ValidateNotNullOrEmpty()]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine] $VM,
        [Parameter(Position = 0)][ValidateNotNullOrEmpty()]
        [string] $DestinationAddress,
        [Parameter(Position = 1)][ValidateNotNullOrEmpty()]
        [string] $DestinationPort
    )
    # Get the network watcher, creating a new one if required
    $networkWatcher = Get-AzNetworkWatcher | Where-Object -Property Location -EQ -Value $VM.Location
    if (-Not $networkWatcher) {
        $networkWatcher = New-AzNetworkWatcher -Name "NetworkWatcher" -ResourceGroupName "NetworkWatcherRG" -Location $VM.Location
    }
    # Ensure that the VM has the extension installed (if we have permissions for this)
    $networkWatcherExtension = Get-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name | Where-Object { ($_.Publisher -eq "Microsoft.Azure.NetworkWatcher") -and ($_.ProvisioningState -eq "Succeeded") }
    if (-Not $networkWatcherExtension) {
        Add-LogMessage -Level Info "... registering the Azure NetworkWatcher extension on $($VM.Name). "
        # Add the Windows extension
        if ($VM.OSProfile.WindowsConfiguration) {
            $_ = Set-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Location $VM.Location -Name "AzureNetworkWatcherExtension" -Publisher "Microsoft.Azure.NetworkWatcher" -Type "NetworkWatcherAgentWindows" -TypeHandlerVersion "1.4" -ErrorVariable NotInstalled -ErrorAction SilentlyContinue
            if ($NotInstalled) {
                Add-LogMessage -Level Warning "Unable to register Windows network watcher extension for $($VM.Name)"
                return "Unknown"
            }
        }
        # Add the Linux extension
        if ($VM.OSProfile.LinuxConfiguration) {
            $_ = Set-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Location $VM.Location -Name "AzureNetworkWatcherExtension" -Publisher "Microsoft.Azure.NetworkWatcher" -Type "NetworkWatcherAgentLinux" -TypeHandlerVersion "1.4" -ErrorVariable NotInstalled -ErrorAction SilentlyContinue
            if ($NotInstalled) {
                Add-LogMessage -Level Warning "Unable to register Linux network watcher extension for $($VM.Name)"
                return "Unknown"
            }
        }
    }
    Add-LogMessage -Level Info "... testing connectivity"
    $networkCheck = Test-AzNetworkWatcherConnectivity -NetworkWatcher $networkWatcher -SourceId $VM.Id -DestinationAddress $DestinationAddress -DestinationPort $DestinationPort -ErrorVariable NotAvailable -ErrorAction SilentlyContinue
    if ($NotAvailable) {
        Add-LogMessage -Level Warning "Unable to test connection for $($VM.Name)"
        return "Unknown"
    } else {
        return $networkCheck.ConnectionStatus
    }
}

function Get-NSGRules {
    param (
        [Parameter(Position = 0)][ValidateNotNullOrEmpty()]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine] $VM
    )
    $effectiveNSG = Get-AzEffectiveNetworkSecurityGroup -NetworkInterfaceName ($VM.NetworkProfile.NetworkInterfaces.Id -Split '/')[-1] -ResourceGroupName $VM.ResourceGroupName -ErrorVariable NotAvailable -ErrorAction SilentlyContinue
    if ($NotAvailable) {
        # Not able to get effective rules so we'll construct them by hand
        $rules = @()
        # Get rules from NSG directly attached to the NIC
        $nic = Get-AzNetworkInterface | Where-Object { $_.Id -eq $VM.NetworkProfile.NetworkInterfaces.Id }
        $directNsgs = Get-AzNetworkSecurityGroup | Where-Object { $_.Id -eq $nic.NetworkSecurityGroup.Id }
        foreach ($directNsg in $directNsgs) {
            $rules = $rules + $directNsg.SecurityRules + $directNsg.DefaultSecurityRules
        }
        # Get rules from NSG attached to the subnet
        $subnetNsgs = Get-AzNetworkSecurityGroup | Where-Object { $_.Subnets.Id -eq $nic.IpConfigurations.Subnet.Id }
        foreach ($subnetNsg in $subnetNsgs) {
            $rules = $rules + $subnetNsg.SecurityRules + $subnetNsg.DefaultSecurityRules
        }
        $effectiveRules = @()
        # Convert each PSSecurityRule into a PSEffectiveSecurityRule
        foreach ($rule in $rules) {
            $effectiveRule = [Microsoft.Azure.Commands.Network.Models.PSEffectiveSecurityRule]::new()
            $effectiveRule.Name = $rule.Name
            $effectiveRule.Protocol = $rule.Protocol.Replace("*", "All")
            # Source port range
            $effectiveRule.SourcePortRange = New-Object System.Collections.Generic.List[string]
            foreach ($port in $rule.SourcePortRange) {
                if ($port -eq "*") { $effectiveRule.SourcePortRange.Add("0-65535"); break }
                elseif ($port.Contains("-")) { $effectiveRule.SourcePortRange.Add($port) }
                else { $effectiveRule.SourcePortRange.Add("$port-$port") }
            }
            # Destination port range
            $effectiveRule.DestinationPortRange = New-Object System.Collections.Generic.List[string]
            foreach ($port in $rule.DestinationPortRange) {
                if ($port -eq "*") { $effectiveRule.DestinationPortRange.Add("0-65535"); break }
                elseif ($port.Contains("-")) { $effectiveRule.DestinationPortRange.Add($port) }
                else { $effectiveRule.DestinationPortRange.Add("$port-$port") }
            }
            # Source address prefix
            $effectiveRule.SourceAddressPrefix = New-Object System.Collections.Generic.List[string]
            foreach ($prefix in $rule.SourceAddressPrefix) {
                if ($prefix -eq "0.0.0.0/0") { $effectiveRule.SourceAddressPrefix.Add("*"); break }
                else { $effectiveRule.SourceAddressPrefix.Add($rule.SourceAddressPrefix) }
            }
            # Destination address prefix
            $effectiveRule.DestinationAddressPrefix = New-Object System.Collections.Generic.List[string]
            foreach ($prefix in $rule.DestinationAddressPrefix) {
                if ($prefix -eq "0.0.0.0/0") { $effectiveRule.DestinationAddressPrefix.Add("*"); break }
                else { $effectiveRule.DestinationAddressPrefix.Add($rule.DestinationAddressPrefix) }
            }
            $effectiveRule.Access = $rule.Access
            $effectiveRule.Priority = $rule.Priority
            $effectiveRule.Direction = $rule.Direction
            $effectiveRules = $effectiveRules + $effectiveRule
        }
        return $effectiveRules
    } else {
        $effectiveRules = $effectiveNSG.EffectiveSecurityRules
        foreach ($effectiveRule in $effectiveRules) {
            if ($effectiveRule.SourceAddressPrefix[0] -eq "0.0.0.0/0") { $effectiveRule.SourceAddressPrefix.Clear(); $effectiveRule.SourceAddressPrefix.Add("*") }
            if ($effectiveRule.DestinationAddressPrefix[0] -eq "0.0.0.0/0") { $effectiveRule.DestinationAddressPrefix.Clear(); $effectiveRule.DestinationAddressPrefix.Add("*") }
        }
        return $effectiveRules
    }
}


# Get original context before switching subscription
# --------------------------------------------------
$originalContext = Get-AzContext


# Get VMs in current SHM
# ----------------------
$_ = Set-AzContext -SubscriptionId $currentSubscription
$currentShmVMs = Get-AzVM | Where-Object { $_.Name -NotLike "*shm-deploy*" }
Add-LogMessage -Level Info "Found $($currentShmVMs.Count) VMs in current subscription: '$currentSubscription'"
foreach ($VM in $currentShmVMs) {
    Add-LogMessage -Level Info "... $($VM.Name)"
}

# Get VMs in new SHM
# ------------------
$_ = Set-AzContext -SubscriptionId $newSubscription
$newShmVMs = Get-AzVM
Add-LogMessage -Level Info "Found $($newShmVMs.Count) VMs in new subscription: '$newSubscription'"
foreach ($VM in $newShmVMs) {
    Add-LogMessage -Level Info "... $($VM.Name)"
}

# Create a hash table which maps current SHM VMs to new ones
# ----------------------------------------------------------
$vmHashTable = @{}
foreach ($currentVM in $currentShmVMs) {
    $nameToCheck = $currentVM.Name
    # Override matches for names that would otherwise fail
    if ($nameToCheck.StartsWith("RDSSH1")) { $nameToCheck = $nameToCheck.Replace("RDSSH1", "APP-SRE") }
    if ($nameToCheck.StartsWith("RDSSH2")) { $nameToCheck = $nameToCheck.Replace("RDSSH2", "DKP-SRE") }
    if ($nameToCheck.StartsWith("CRAN-MIRROR")) { $nameToCheck = $nameToCheck.Replace("MIRROR", "") }
    if ($nameToCheck.StartsWith("PYPI-MIRROR")) { $nameToCheck = $nameToCheck.Replace("MIRROR", "") }
    # Only match against names that have not been matched yet
    $newShmVMNames = $newShmVMs | ForEach-Object { $_.Name } | Where-Object { ($vmHashTable.Values | ForEach-Object { $_.Name }) -NotContains $_ }
    $newVM = $newShmVMs | Where-Object { $_.Name -eq $(Select-ClosestMatch -Array $newShmVMNames -Value $nameToCheck) }
    $vmHashTable[$currentVM] = $newVM
    Add-LogMessage -Level Info "matched $($currentVM.Name) => $($newVM.Name)"
}

# Iterate over paired VMs checking their network settings
# -------------------------------------------------------
foreach ($currentVM in $currentShmVMs) {
    $newVM = $vmHashTable[$currentVM]

    # Get parameters for current VM
    # -----------------------------
    $_ = Set-AzContext -SubscriptionId $currentSubscription
    Add-LogMessage -Level Info "Getting NSG rules and connectivity for $($currentVM.Name)"
    $currentRules = Get-NSGRules -VM $currentVM
    $currentInternetCheck = Test-OutboundConnection -VM $currentVM -DestinationAddress "google.com" -DestinationPort 80

    # Get parameters for new VM
    # -------------------------
    $_ = Set-AzContext -SubscriptionId $newSubscription
    Add-LogMessage -Level Info "Getting NSG rules and connectivity for $($newVM.Name)"
    $newRules = Get-NSGRules -VM $newVM
    $newInternetCheck = Test-OutboundConnection -VM $newVM -DestinationAddress "google.com" -DestinationPort 80

    # Check that each NSG rule has a matching equivalent (which might be named differently)
    Add-LogMessage -Level Info "Comparing NSG rules for $($currentVM.Name) and $($newVM.Name)"
    Add-LogMessage -Level Info "... ensuring that all $($currentVM.Name) rules exist on $($newVM.Name)"
    Compare-NSGRules -CurrentRules $currentRules -NewRules $newRules
    Add-LogMessage -Level Info "... ensuring that all $($newVM.Name) rules exist on $($currentVM.Name)"
    Compare-NSGRules -CurrentRules $newRules -NewRules $currentRules

    # Check that internet connectivity is the same for matched VMs
    Add-LogMessage -Level Info "Comparing internet connectivity for $($currentVM.Name) and $($newVM.Name)..."
    if ($currentInternetCheck -eq $newInternetCheck) {
        Add-LogMessage -Level Success "The internet is '$($currentInternetCheck)' from both"
    } else {
        Add-LogMessage -Level Failure "The internet is '$($currentInternetCheck)' from $($currentVM.Name)"
        Add-LogMessage -Level Failure "The internet is '$($newInternetCheck)' from $($newVM.Name)"
    }
}


# Switch back to original subscription
# ------------------------------------
$_ = Set-AzContext -Context $originalContext
