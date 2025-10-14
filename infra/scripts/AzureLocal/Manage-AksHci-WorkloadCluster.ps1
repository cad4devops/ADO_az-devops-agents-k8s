# New-AksHci-WorkloadCluster.ps1
# This script creates a new AKS workload cluster with both Windows and Linux nodes, and retrieves
# the AKS credentials based on an instance number (e.g., "003").
#
# Usage:
#   .\New-AksHci-WorkloadCluster.ps1 -InstanceNumber 003
#   .\New-AksHci-WorkloadCluster.ps1 -InstanceNumber 003 -AutoApprove
#  Get-AksHciVmSize > VmSizes.txt
# Notes:
# - Requires Windows PowerShell 5.x and the AksHci PowerShell module available in the session.
# - The script will list existing clusters/VMs and prompt before creating a new cluster unless
#   -AutoApprove is supplied.

param(
    [Parameter(Mandatory = $true)]
    [string]$InstanceNumber,
    [switch]$AutoApprove,
    # Top-level overrides (optional). Defaults will be computed from InstanceNumber when not supplied.
    [string]$ClusterName,
    [string]$KubeConfigPath,
    [string]$LinuxNodePoolName,
    [string]$WindowsNodePoolName,
    [int]$LinuxNodeCount = 2,
    [int]$WindowsNodeCount = 2,
    [int]$LinuxPoolNumber = 1,
    [int]$WindowsPoolNumber = 1,
    [string]$LinuxNodeVmSize = "Standard_D2s_v3",
    [string]$WindowsNodeVmSize = "Standard_D4s_v3",
    [string]$LinuxOsSku = "CBLMariner",
    [string]$WindowsOsSku = "Windows2022",
    [string]$KubernetesVersion = "v1.29.4",
    [switch]$DeleteCluster,
    # When a cluster exists but is not yet 'Deployed', optionally wait until it becomes healthy
    [switch]$WaitForProvisioning,
    [int]$ProvisioningTimeoutMinutes = 30,
    [int]$ProvisioningPollSeconds = 15,
    [switch]$CollectDiagnosticsOnFailure,
    # Optional: upload the resulting kubeconfig to Azure DevOps secure files using scripts/upload-secure-file-rest.ps1
    [switch]$UploadKubeconfig,
    [string]$SecureFilePAT,
    [string]$AzureDevOpsOrg,
    [string]$AzureDevOpsProjectID,
    [string]$SecureFileName
)

# Fail fast on unsupported PowerShell runtimes
# Requirement: run under Windows PowerShell 5.x (Windows PowerShell / Windows PowerShell 5.1).
# PowerShell Core (pwsh) 7+ is not supported for this script.
try {
    $psMajor = $PSVersionTable.PSVersion.Major
}
catch {
    Write-Error "Unable to determine PowerShell version. This script requires Windows PowerShell 5.x (PowerShell Core 7+ is not supported)."
    exit 1
}

# If running PowerShell Core (major >= 7) -> fail
if ($psMajor -ge 7) {
    Write-Error "PowerShell Core (pwsh) 7+ is not supported by this script. Please run this script with Windows PowerShell 5.x (for example, PowerShell 5.1)."
    exit 1
}

# Determine if running on Windows in a way that works in Windows PowerShell 5.x
if (Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) {
    $RunningOnWindows = $IsWindows
}
else {
    # Fallback: on Windows PowerShell, the OS environment variable is typically 'Windows_NT'
    $RunningOnWindows = ($env:OS -eq 'Windows_NT')
}

# If not Windows platform or not PS v5 -> fail
if ($psMajor -ne 5 -or -not $RunningOnWindows) {
    Write-Error "Unsupported PowerShell runtime. This script requires Windows PowerShell 5.x on Windows (PowerShell Core 7+ not supported)."
    exit 1
}

# Compute defaults from InstanceNumber when not provided as parameters
if ([string]::IsNullOrWhiteSpace($ClusterName)) {
    $ClusterName = "workload-cluster-$InstanceNumber"
}

if ([string]::IsNullOrWhiteSpace($KubeConfigPath)) {
    $KubeConfigPath = "$env:USERPROFILE\.kube\$ClusterName-kubeconfig.yaml"
}

$cluster = $null
$windowsPoolSatisfied = $false
$linuxPoolSatisfied = $false

# Helper: determine the next pool instance number for an OS (returns a zero-padded 3-digit string)
function Get-NextPoolInstanceNumber {
    param(
        [string]$Cluster,
        [ValidateSet('linux', 'windows')]
        [string]$OsType
    )

    $osToken = $OsType.ToLower()
    $pattern = "{0}-{1}-pool-(\d+)" -f ([regex]::Escape($Cluster)), $osToken
    $found = @()

    # Try AksHci node pools first (pass clusterName to avoid interactive prompts)
    if (Get-Command -Name Get-AksHciNodePool -ErrorAction SilentlyContinue) {
        try {
            $pools = Get-AksHciNodePool -clusterName $Cluster -ErrorAction SilentlyContinue
        }
        catch {
            $pools = $null
        }

        if ($pools) {
            foreach ($p in $pools) {
                if ($p.Name -match $pattern) {
                    $found += [int]$Matches[1]
                }
            }
        }
    }

    # Fallback: inspect Hyper-V VM names for matching pool patterns
    if ($found.Count -eq 0) {
        try {
            $vms = Get-VM -Name "$Cluster*" -ErrorAction SilentlyContinue
        }
        catch {
            $vms = $null
        }

        if ($vms) {
            foreach ($vm in $vms) {
                if ($vm.Name -match $pattern) {
                    $found += [int]$Matches[1]
                }
            }
        }
    }

    $next = 1
    if ($found.Count -gt 0) { $next = ($found | Measure-Object -Maximum).Maximum + 1 }
    return $next.ToString('000')
}

# Collect useful diagnostics into a folder for offline analysis
function Collect-Diagnostics {
    param(
        [Parameter(Mandatory = $true)][string]$ClusterName,
        [Parameter(Mandatory = $true)][string]$OutDir
    )
    try {
        if (-not (Test-Path -Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
        Write-Host ("Collecting diagnostics for cluster {0} into {1}" -f $ClusterName, $OutDir)

        # Save AksHci cluster object
        if (Get-Command -Name Get-AksHciCluster -ErrorAction SilentlyContinue) {
            try { Get-AksHciCluster | Where-Object { $_.Name -eq $ClusterName } | Format-List * > (Join-Path $OutDir 'aks-hci-cluster.txt') } catch { Write-Warning "Failed to save Get-AksHciCluster output: $_" }
        }

        # Save node pool info
        if (Get-Command -Name Get-AksHciNodePool -ErrorAction SilentlyContinue) {
            try { Get-AksHciNodePool -clusterName $ClusterName | Format-List * > (Join-Path $OutDir 'aks-hci-nodepools.txt') } catch { Write-Warning "Failed to save Get-AksHciNodePool output: $_" }
        }

        # Save Hyper-V VM status
        try { Get-VM -Name "$ClusterName*" | Select-Object Name, State, Status | Format-Table -AutoSize > (Join-Path $OutDir 'hyperv-vms.txt') } catch { Write-Warning "Failed to save Get-VM output: $_" }

        # If kvactl exists, collect cluster show and nodepool list (kvactl flags vary by version)
        $kvactl = Get-Command -Name kvactl -ErrorAction SilentlyContinue
        if ($kvactl) {
            try {
                & $kvactl.Path 'cluster' 'show' $ClusterName > (Join-Path $OutDir 'kvactl-cluster-show.txt') 2>&1
            }
            catch { Write-Warning "kvactl cluster show failed: $_" }
        }

        Write-Host "Diagnostics collection complete. Files in: $OutDir"
    }
    catch {
        Write-Warning ("Failed to collect diagnostics: {0}" -f $_.Exception.Message)
    }
}

# Node pool names: if not provided, generate names using provided per-OS pool numbers (zero-padded)
if ([string]::IsNullOrWhiteSpace($LinuxNodePoolName)) {
    if ($LinuxPoolNumber -gt 0) {
        $linuxPoolInstance = '{0:000}' -f $LinuxPoolNumber
    }
    else {
        $linuxPoolInstance = Get-NextPoolInstanceNumber -Cluster $ClusterName -OsType 'linux'
    }
    $LinuxNodePoolName = "{0}-linux-pool-{1}" -f $ClusterName, $linuxPoolInstance
}

if ([string]::IsNullOrWhiteSpace($WindowsNodePoolName)) {
    if ($WindowsPoolNumber -gt 0) {
        $windowsPoolInstance = '{0:000}' -f $WindowsPoolNumber
    }
    else {
        $windowsPoolInstance = Get-NextPoolInstanceNumber -Cluster $ClusterName -OsType 'windows'
    }
    $WindowsNodePoolName = "{0}-windows-pool-{1}" -f $ClusterName, $windowsPoolInstance
}

# Node counts, VM sizes, OS SKUs and KubernetesVersion have sensible defaults declared in the param block

Write-Host "Checking for existing workload clusters..."

# Try to list existing clusters using AksHci cmd if present, otherwise fallback to Hyper-V VM names
if (Get-Command -Name Get-AksHciCluster -ErrorAction SilentlyContinue) {
    try {
        $existingClusters = Get-AksHciCluster -ErrorAction Stop
    }
    catch {
        Write-Warning ("Unable to list clusters with Get-AksHciCluster: {0}" -f $_.Exception.Message)
        $existingClusters = $null
    }
}
else {
    try {
        $existingClusters = Get-VM -Name "$ClusterName*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue
    }
    catch {
        $existingClusters = $null
    }
}

if ($existingClusters) {
    Write-Host "Existing clusters / VMs found:"
    foreach ($item in $existingClusters) {
        if ($item -is [string]) {
            Write-Host " - $item"
        }
        else {
            $name = $null
            if ($item.PSObject.Properties.Name -contains 'Name') { $name = $item.Name }
            elseif ($item.PSObject.Properties.Name -contains 'ClusterName') { $name = $item.ClusterName }

            $poolsText = ''
            if ($item.PSObject.Properties.Name -contains 'NodePools') {
                $poolProp = $item.NodePools
                if ($poolProp) {
                    if ($poolProp -is [string]) { $poolsText = ($poolProp -split ',') -join ', ' }
                    elseif ($poolProp -is [System.Collections.IEnumerable]) {
                        $poolsText = ($poolProp | ForEach-Object {
                                if ($_ -is [string]) { $_ }
                                elseif ($_.PSObject.Properties.Name -contains 'Name') { $_.Name }
                                elseif ($_.PSObject.Properties.Name -contains 'NodePoolName') { $_.NodePoolName }
                                else { $_.ToString() }
                            }) -join ', '
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($name)) { $name = $item.ToString() }
            if ([string]::IsNullOrWhiteSpace($poolsText)) { $poolsText = 'n/a' }
            Write-Host (" - {0} (NodePools: {1})" -f $name, $poolsText)
        }
    }
    # If the user asked to delete, confirm delete specifically and perform deletion now
    if ($DeleteCluster) {
        if (-not $AutoApprove) {
            $resp = Read-Host -Prompt "Delete cluster '$ClusterName' and all associated resources? This is destructive. (Y/N)"
            if ($resp -notin 'Y', 'y', 'Yes', 'yes') {
                Write-Host "Aborting delete as requested by user."
                exit 0
            }
        }

        # Define a function to perform deletion so we can keep logic tidy
        function Do-DeleteCluster {
            param([string]$Name)

            # Prefer Remove-AksHciCluster if available. Only include -Force when the cmdlet actually supports it.
            if (Get-Command -Name Remove-AksHciCluster -ErrorAction SilentlyContinue) {
                try {
                    $removeCmd = Get-Command -Name Remove-AksHciCluster -ErrorAction SilentlyContinue
                    $supportsForce = $false
                    $supportsConfirm = $false
                    if ($removeCmd -and $removeCmd.Parameters) {
                        $supportsForce = $removeCmd.Parameters.Keys -contains 'Force'
                        $supportsConfirm = $removeCmd.Parameters.Keys -contains 'Confirm'
                    }
                    Write-Host "Removing cluster $Name via Remove-AksHciCluster..."
                    # Prefer to call with -Force and -Confirm:$false when available to be non-interactive
                    if ($supportsForce -and $supportsConfirm) {
                        Remove-AksHciCluster -Name $Name -Force -Confirm:$false -ErrorAction Stop
                    }
                    elseif ($supportsForce) {
                        Remove-AksHciCluster -Name $Name -Force -ErrorAction Stop
                    }
                    elseif ($supportsConfirm) {
                        Remove-AksHciCluster -Name $Name -Confirm:$false -ErrorAction Stop
                    }
                    else {
                        Remove-AksHciCluster -Name $Name -ErrorAction Stop
                    }
                    Write-Host "Cluster $Name removed via AksHci cmdlet."
                    return
                }
                catch {
                    Write-Warning ("Remove-AksHciCluster failed: {0}" -f $_.Exception.Message)
                    Write-Host "Falling back to Hyper-V VM removal..."
                }
            }

            # Fallback: remove Hyper-V VMs matching the cluster name
            try {
                $vms = Get-VM -Name "$Name*" -ErrorAction SilentlyContinue
                if ($vms) {
                    Write-Host "Stopping and removing Hyper-V VMs matching '$Name*'..."
                    foreach ($vm in $vms) {
                        try {
                            # Attempt to stop the VM if it's not already off
                            if ($vm.State -ne 'Off') {
                                Stop-VM -VM $vm -Force -TurnOff -Confirm:$false -ErrorAction Stop
                                Start-Sleep -Seconds 2
                            }
                        }
                        catch {
                            Write-Warning ("Failed to stop VM {0}: {1}" -f $vm.Name, $_.Exception.Message)
                        }

                        try {
                            Remove-VM -VM $vm -Force -Confirm:$false -ErrorAction Stop
                            Write-Host ("Removed VM {0}" -f $vm.Name)
                        }
                        catch {
                            Write-Warning ("Failed to remove VM {0}: {1}" -f $vm.Name, $_.Exception.Message)
                        }
                    }
                }
                else {
                    Write-Warning "No Hyper-V VMs found matching '$Name*'. Nothing to delete."
                }
            }
            catch {
                Write-Warning ("Failed to remove Hyper-V VMs: {0}" -f $_.Exception.Message)
            }

            Write-Host "Delete operation complete (or attempted)."
        }

        Do-DeleteCluster -Name $ClusterName
        Write-Host "Exiting script after delete operation."; exit 0
    }

    # Otherwise, confirm creation (do not prompt to create when user specifically requested delete)
    if (-not $AutoApprove) {
        $resp = Read-Host -Prompt "Existing clusters detected. Proceed with creating $ClusterName? (Y/N)"
        if ($resp -notin 'Y', 'y', 'Yes', 'yes') {
            Write-Host "Aborting as requested by user."
            exit 0
        }
    }
}
else {
    Write-Host "No existing clusters detected by local checks."
}

# If the cluster already exists, inspect node pools and ensure they match desired configuration
if ($existingClusters -and (Get-Command -Name Get-AksHciCluster -ErrorAction SilentlyContinue)) {
    $cluster = Get-AksHciCluster | Where-Object { $_.Name -eq $ClusterName }
    if ($cluster) {
        Write-Host "Cluster $ClusterName exists. Verifying node pools..."

        # Quick health check: ensure cluster provisioning state is 'Deployed' before attempting pool changes
        $provState = $null
        try {
            if ($cluster.PSObject.Properties.Name -contains 'ProvisioningState') { $provState = $cluster.ProvisioningState }
            elseif ($cluster.PSObject.Properties.Name -contains 'Status') {
                # Some module versions use Status/Phase
                if ($cluster.Status -and $cluster.Status.Phase) { $provState = $cluster.Status.Phase }
            }
        }
        catch { $provState = $null }

        if ($provState -and ($provState -ne 'Deployed')) {
            Write-Host ("Cluster {0} is currently in Provisioning/Phase='{1}'." -f $ClusterName, $provState)
            if ($WaitForProvisioning) {
                Write-Host ("Waiting up to {0} minutes for cluster to reach 'Deployed'..." -f $ProvisioningTimeoutMinutes)
                $deadline = (Get-Date).AddMinutes($ProvisioningTimeoutMinutes)
                do {
                    Start-Sleep -Seconds $ProvisioningPollSeconds
                    try {
                        $cluster = Get-AksHciCluster | Where-Object { $_.Name -eq $ClusterName }
                        $provState = $null
                        if ($cluster) {
                            if ($cluster.PSObject.Properties.Name -contains 'ProvisioningState') { $provState = $cluster.ProvisioningState }
                            elseif ($cluster.PSObject.Properties.Name -contains 'Status') { if ($cluster.Status -and $cluster.Status.Phase) { $provState = $cluster.Status.Phase } }
                        }
                        Write-Host ("Current provisioning state: {0}; waiting..." -f $provState)
                    }
                    catch { Write-Warning ("Failed to re-query cluster state: {0}" -f $_.Exception.Message) }
                } while ((Get-Date) -lt $deadline -and $provState -and ($provState -ne 'Deployed'))

                if ($provState -ne 'Deployed') {
                    Write-Error ("Cluster {0} did not reach 'Deployed' within the timeout (current state: {1})." -f $ClusterName, $provState)
                    if ($CollectDiagnosticsOnFailure) {
                        Collect-Diagnostics -ClusterName $ClusterName -OutDir (Join-Path -Path $PSScriptRoot -ChildPath "diagnostics-$ClusterName-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
                    }
                    Write-Host "Cluster object details (trimmed):"
                    $cluster | Select-Object Name, ProvisioningState, @{Name = 'Phase'; Expression = { if ($_.Status -and $_.Status.Phase) { $_.Status.Phase }else { '' } } }, NodePools | Format-List
                    exit 2
                }
                else {
                    Write-Host "Cluster reached 'Deployed'. Continuing node pool operations."
                }
            }
            else {
                Write-Error ("Cluster {0} is not in a healthy/provisioned state: Provisioning/Phase='{1}'. Aborting node pool operations so you can inspect the cluster." -f $ClusterName, $provState)
                Write-Host "Cluster object details (trimmed):"
                $cluster | Select-Object Name, ProvisioningState, @{Name = 'Phase'; Expression = { if ($_.Status -and $_.Status.Phase) { $_.Status.Phase }else { '' } } }, NodePools | Format-List
                exit 2
            }
        }

        # Get node pools for this cluster
        if (Get-Command -Name Get-AksHciNodePool -ErrorAction SilentlyContinue) {
            try {
                $nodePools = Get-AksHciNodePool -clusterName $ClusterName -ErrorAction Stop
            }
            catch {
                Write-Warning ("Unable to list node pools for {0}: {1}" -f $ClusterName, $_.Exception.Message)
                $nodePools = $null
            }

            if ($nodePools) {
                # Build a map of existing pool names -> objects (when available) and a simple name list
                $poolByName = @{}
                $existingPoolNames = @()
                foreach ($p in $nodePools) {
                    if ($p -is [string]) {
                        $existingPoolNames += $p
                    }
                    elseif ($p.PSObject.Properties.Name -contains 'Name') {
                        $name = $p.Name
                        if ($name) {
                            $existingPoolNames += $name
                            $poolByName[$name] = $p
                        }
                    }
                    elseif ($p.PSObject.Properties.Name -contains 'NodePoolName') {
                        $name = $p.NodePoolName
                        if ($name) {
                            $existingPoolNames += $name
                            $poolByName[$name] = $p
                        }
                    }
                    else {
                        # Fallback to string conversion
                        $existingPoolNames += $p.ToString()
                    }
                }

                # Also include any names reported on the cluster object (some module versions place pool names there)
                if ($cluster -and $cluster.PSObject.Properties.Name -contains 'NodePools') {
                    $np = $cluster.NodePools
                    if ($np) {
                        if ($np -is [string]) {
                            $existingPoolNames += ($np -split ',') | ForEach-Object { $_.Trim() }
                        }
                        elseif ($np -is [System.Collections.IEnumerable]) {
                            foreach ($item in $np) {
                                if ($item -is [string]) { $existingPoolNames += $item }
                                elseif ($item.PSObject.Properties.Name -contains 'Name') { $existingPoolNames += $item.Name }
                            }
                        }
                    }
                }

                # make unique
                $existingPoolNames = $existingPoolNames | Where-Object { $_ } | Select-Object -Unique

                # Helper: check+update pool
                function Ensure-NodePool([string]$desiredName, [int]$desiredCount, [string]$desiredVmSize, [string]$osType) {
                    $poolExists = $existingPoolNames -contains $desiredName
                    if ($poolExists) {
                        # Try to obtain a detailed object for the pool
                        $existingPool = $null
                        if ($poolByName.ContainsKey($desiredName)) { $existingPool = $poolByName[$desiredName] }
                        else {
                            # Try fetching the specific pool if supported
                            if (Get-Command -Name Get-AksHciNodePool -ErrorAction SilentlyContinue) {
                                try { $existingPool = Get-AksHciNodePool -clusterName $ClusterName -name $desiredName -ErrorAction SilentlyContinue } catch { $existingPool = $null }
                            }
                        }

                        if ($existingPool) {
                            # Normalize current values (some module versions may omit properties)
                            $currentCount = 0
                            $currentVmSize = ''
                            try { if ($existingPool.PSObject.Properties.Name -contains 'Count') { $currentCount = [int]$existingPool.Count } }
                            catch { $currentCount = 0 }
                            try { if ($existingPool.PSObject.Properties.Name -contains 'VmSize') { $currentVmSize = $existingPool.VmSize } }
                            catch { $currentVmSize = '' }

                            if ($currentCount -ne $desiredCount) {
                                Write-Host ("Scaling node pool '{0}' from {1} to {2}..." -f $desiredName, $currentCount, $desiredCount)
                                if (Get-Command -Name Set-AksHciNodePool -ErrorAction SilentlyContinue) {
                                    Set-AksHciNodePool -clusterName $ClusterName -name $desiredName -count $desiredCount -ErrorAction SilentlyContinue
                                }
                                else {
                                    Write-Warning "Set-AksHciNodePool not available; attempting New-AksHciNodePool with updated count may fail or create duplicate."
                                    try { New-AksHciNodePool -clusterName $ClusterName -name $desiredName -count $desiredCount -vmSize $desiredVmSize -osType $osType -ErrorAction Stop } catch { Write-Warning ("Scaling via New-AksHciNodePool failed: {0}" -f $_.Exception.Message) }
                                }
                            }
                            if ($currentVmSize -and ($currentVmSize -ne $desiredVmSize)) {
                                Write-Host ("Updating VM size for node pool '{0}' from {1} to {2}..." -f $desiredName, $currentVmSize, $desiredVmSize)
                                if (Get-Command -Name Set-AksHciNodePool -ErrorAction SilentlyContinue) {
                                    Set-AksHciNodePool -clusterName $ClusterName -name $desiredName -vmSize $desiredVmSize -ErrorAction SilentlyContinue
                                }
                                else {
                                    Write-Warning "Set-AksHciNodePool not available to change VM size. Manual action may be required."
                                }
                            }
                        }
                        else {
                            Write-Host "Node pool '$desiredName' already exists but detailed properties unavailable; skipping creation and scaling."
                        }
                    }
                    else {
                        Write-Host "Node pool '$desiredName' not found; creating..."
                        try {
                            $nodePoolOsSku = $LinuxOsSku
                            if ($osType -eq 'Windows') { $nodePoolOsSku = $WindowsOsSku }
                            New-AksHciNodePool -clusterName $ClusterName -name $desiredName -count $desiredCount -vmSize $desiredVmSize -osType $osType -osSku $nodePoolOsSku -ErrorAction Stop
                        }
                        catch {
                            Write-Warning ("Failed to create node pool {0}: {1}" -f $desiredName, $_.Exception.Message)
                        }
                    }
                }

                # Ensure Linux pool
                Ensure-NodePool -desiredName $LinuxNodePoolName -desiredCount $LinuxNodeCount -desiredVmSize $LinuxNodeVmSize -osType 'Linux'

                # Ensure Windows pool
                Ensure-NodePool -desiredName $WindowsNodePoolName -desiredCount $WindowsNodeCount -desiredVmSize $WindowsNodeVmSize -osType 'Windows'

                try {
                    $verifyPools = Get-AksHciNodePool -clusterName $ClusterName -ErrorAction SilentlyContinue
                }
                catch {
                    $verifyPools = $null
                }

                if ($verifyPools) {
                    $linuxPoolSatisfied = $verifyPools | Where-Object {
                        ($_ -is [string] -and $_ -eq $LinuxNodePoolName) -or
                        ($_.PSObject.Properties.Name -contains 'Name' -and $_.Name -eq $LinuxNodePoolName) -or
                        ($_.PSObject.Properties.Name -contains 'NodePoolName' -and $_.NodePoolName -eq $LinuxNodePoolName)
                    }
                    $linuxPoolSatisfied = [bool]$linuxPoolSatisfied

                    $windowsPoolSatisfied = $verifyPools | Where-Object {
                        ($_ -is [string] -and $_ -eq $WindowsNodePoolName) -or
                        ($_.PSObject.Properties.Name -contains 'Name' -and $_.Name -eq $WindowsNodePoolName) -or
                        ($_.PSObject.Properties.Name -contains 'NodePoolName' -and $_.NodePoolName -eq $WindowsNodePoolName)
                    }
                    $windowsPoolSatisfied = [bool]$windowsPoolSatisfied
                }
                else {
                    $linuxPoolSatisfied = $existingPoolNames -contains $LinuxNodePoolName
                    $windowsPoolSatisfied = $existingPoolNames -contains $WindowsNodePoolName
                }

            }
            else {
                Write-Warning "No node pool information available for $ClusterName."
            }
        }
        else {
            Write-Warning "Get-AksHciNodePool not available; cannot inspect or scale node pools programmatically."
        }
    }
    else {
        Write-Host "Cluster $ClusterName not listed by Get-AksHciCluster; proceeding to create."
    }
}

# Only create the cluster if it does not already exist
if (-not $cluster) {
    Write-Host "Creating AKS workload cluster: $ClusterName (Linux node pool first)..."

    # Create the initial Linux node pool (New-AksHciCluster creates the cluster and its initial node pool)
    if (-not (Get-Command -Name New-AksHciCluster -ErrorAction SilentlyContinue)) {
        Write-Error "Required command 'New-AksHciCluster' not found. Ensure the AksHci module is installed and imported."
        exit 1
    }

    try {
        New-AksHciCluster -name $ClusterName `
            -nodePoolName $LinuxNodePoolName `
            -nodeCount $LinuxNodeCount `
            -nodeVmSize $LinuxNodeVmSize `
            -osType Linux `
            -osSku $LinuxOsSku `
            -kubernetesVersion $KubernetesVersion -ErrorAction Stop
        $linuxPoolSatisfied = $true
    }
    catch {
        Write-Error ("Failed to create AKS workload cluster {0} (Linux node pool): {1}" -f $ClusterName, $_.Exception.Message)
        exit 1
    }

    Write-Host "Linux node pool created. Creating Windows node pool (if supported)..."
}
else {
    Write-Host "Cluster $ClusterName already exists; skipping cluster creation step."
}

# Ensure Linux pool exists for pre-created clusters
if ($cluster -and -not $linuxPoolSatisfied -and (Get-Command -Name New-AksHciNodePool -ErrorAction SilentlyContinue)) {
    try {
        Write-Host "Creating Linux node pool $LinuxNodePoolName (not detected in existing cluster state)."
        New-AksHciNodePool -clusterName $ClusterName `
            -name $LinuxNodePoolName `
            -count $LinuxNodeCount `
            -vmSize $LinuxNodeVmSize `
            -osType Linux `
            -osSku $LinuxOsSku -ErrorAction Stop
        $linuxPoolSatisfied = $true
    }
    catch {
        Write-Warning ("Failed to create Linux node pool: {0}" -f $_.Exception.Message)
    }
}
elseif ($cluster -and $linuxPoolSatisfied) {
    Write-Host "Linux node pool $LinuxNodePoolName already aligned with desired configuration; skipping creation."
}
elseif ($cluster) {
    Write-Warning "Command 'New-AksHciNodePool' not available. Cannot create missing Linux node pool."
}

# Create Windows node pool using New-AksHciNodePool if available
if (-not $windowsPoolSatisfied -and (Get-Command -Name New-AksHciNodePool -ErrorAction SilentlyContinue)) {
    try {
        Write-Host "Creating Windows node pool $WindowsNodePoolName (not detected in existing cluster state)."
        New-AksHciNodePool -clusterName $ClusterName `
            -name $WindowsNodePoolName `
            -count $WindowsNodeCount `
            -vmSize $WindowsNodeVmSize `
            -osType Windows `
            -osSku $WindowsOsSku `
            -taints 'sku=windows:NoSchedule' -ErrorAction Stop
        $windowsPoolSatisfied = $true
    }
    catch {
        Write-Warning ("Failed to create Windows node pool: {0}" -f $_.Exception.Message)
    }
}
elseif ($windowsPoolSatisfied) {
    Write-Host "Windows node pool $WindowsNodePoolName already aligned with desired configuration; skipping creation."
}
else {
    Write-Warning "Command 'New-AksHciNodePool' not available. Skipping Windows node pool creation."
}

Write-Host "Cluster $ClusterName created (or partially created). Getting credentials..."

# Get AKS credentials for the new cluster (use Get-AksHciCredential if available)
if (-not (Get-Command -Name Get-AksHciCredential -ErrorAction SilentlyContinue)) {
    Write-Error "Required command 'Get-AksHciCredential' not found. Ensure the AksHci module is installed and imported."
    exit 1
}

try {
    # When running in automated mode try to be non-interactive even if the underlying cmdlet
    # doesn't honour -Confirm:$false by temporarily lowering ConfirmPreference.
    $oldConfirmPref = $ConfirmPreference
    if ($AutoApprove) { $ConfirmPreference = 'None' }
    try {
        $getCmd = Get-Command -Name Get-AksHciCredential -ErrorAction SilentlyContinue
        $supportsForce = $false
        $supportsConfirm = $false
        if ($getCmd -and $getCmd.Parameters) {
            $supportsForce = $getCmd.Parameters.Keys -contains 'Force'
            $supportsConfirm = $getCmd.Parameters.Keys -contains 'Confirm'
        }

        if ($AutoApprove) {
            if ($supportsForce -and $supportsConfirm) {
                Get-AksHciCredential -name $ClusterName -ConfigPath $KubeConfigPath -Force -Confirm:$false -ErrorAction Stop
            }
            elseif ($supportsForce) {
                Get-AksHciCredential -name $ClusterName -ConfigPath $KubeConfigPath -Force -ErrorAction Stop
            }
            elseif ($supportsConfirm) {
                Get-AksHciCredential -name $ClusterName -ConfigPath $KubeConfigPath -Confirm:$false -ErrorAction Stop
            }
            else {
                Get-AksHciCredential -name $ClusterName -ConfigPath $KubeConfigPath -ErrorAction Stop
            }
        }
        else {
            Get-AksHciCredential -name $ClusterName -ConfigPath $KubeConfigPath -ErrorAction Stop
        }
    }
    finally {
        # Restore original preference
        $ConfirmPreference = $oldConfirmPref
    }
}
catch {
    $msg = $_.Exception.Message
    Write-Error ("Failed to get credentials for {0}: {1}" -f ${ClusterName}, $msg)
    exit 1
}

Write-Host "Kubeconfig saved to $KubeConfigPath."
Write-Host "You can now use kubectl with: kubectl --kubeconfig=$KubeConfigPath get nodes"

# Optionally upload kubeconfig to Azure DevOps secure files
if ($UploadKubeconfig -or (-not [string]::IsNullOrWhiteSpace($SecureFilePAT))) {
    # Validate required parameters
    if (-not $UploadKubeconfig) { $UploadKubeconfig = $true }
    if ([string]::IsNullOrWhiteSpace($SecureFilePAT) -or [string]::IsNullOrWhiteSpace($AzureDevOpsOrg) -or [string]::IsNullOrWhiteSpace($AzureDevOpsProjectID)) {
        Write-Warning "Upload requested but one or more Azure DevOps upload parameters are missing (SecureFilePAT/AzureDevOpsOrg/AzureDevOpsProjectID). Skipping upload."
    }
    else {
        if (-not (Test-Path -Path $KubeConfigPath)) { Write-Warning "Kubeconfig not found at $KubeConfigPath; skipping upload." }
        else {
            try {
                # Resolve upload script relative to this script's directory. Manage-AksHci-WorkloadCluster.ps1 is located at infra/scripts/AzureLocal
                $uploadScriptRel = Join-Path -Path $PSScriptRoot -ChildPath '..\..\..\scripts\upload-secure-file-rest.ps1'
                $uploadScript = Get-Item -Path $uploadScriptRel -ErrorAction Stop
                $uploadScriptPath = $uploadScript.FullName

                $secureNameToUse = $SecureFileName
                if ([string]::IsNullOrWhiteSpace($secureNameToUse)) { $secureNameToUse = Split-Path -Path $KubeConfigPath -Leaf }

                Write-Host "Uploading kubeconfig '$KubeConfigPath' as secure file '$secureNameToUse' using $uploadScriptPath"
                & $uploadScriptPath -PAT $SecureFilePAT -AzureDevOpsOrg $AzureDevOpsOrg -AzureDevOpsProjectID $AzureDevOpsProjectID -SecureNameFile2Upload $secureNameToUse -SecureNameFilePath2Upload $KubeConfigPath
                $uploadExit = $LASTEXITCODE
                if ($uploadExit -eq 0) { Write-Host "Kubeconfig uploaded successfully as secure file '$secureNameToUse'." }
                else { Write-Warning ("Upload script exited with code {0}" -f $uploadExit) }
            }
            catch {
                Write-Warning ("Failed to upload kubeconfig: {0}" -f $_.Exception.Message)
            }
        }
    }
}
