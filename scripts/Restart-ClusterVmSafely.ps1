[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [Alias('Name')]
    [string[]]$VMName,

    [string]$ClusterPrefix = "workload-cluster-",

    [string]$InstanceNumber,

    [int]$RestartTimeoutMinutes = 10
)

begin {
    $timeout = [TimeSpan]::FromMinutes($RestartTimeoutMinutes)
    $targetNames = New-Object System.Collections.Generic.HashSet[string]
}

process {
    foreach ($name in $VMName) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $null = $targetNames.Add($name)
    }
}

end {
    if ($ClusterPrefix) {
        $pattern = if ($InstanceNumber) {
            "{0}{1}*" -f $ClusterPrefix, $InstanceNumber
        }
        else {
            "$ClusterPrefix*"
        }

        $vmMatches = Get-VM -ErrorAction Stop | Where-Object { $_.Name -like $pattern }

        if (-not $vmMatches) {
            throw "No Hyper-V VMs found matching pattern '$pattern'."
        }

        foreach ($vm in $vmMatches) {
            $null = $targetNames.Add($vm.Name)
        }
    }

    if ($targetNames.Count -eq 0) {
        throw 'Provide -VMName or -ClusterPrefix (optionally with -InstanceNumber) to select VMs.'
    }

    $names = $targetNames | Sort-Object
    foreach ($name in $names) {
        if (-not $PSCmdlet.ShouldProcess($name, 'Hyper-V VM stop/start')) {
            continue
        }

        try {
            Write-Verbose "Stopping VM $name"
            Stop-VM -Name $name -TurnOff -Confirm:$false -ErrorAction Stop

            $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $vm = $null
            while ($stopwatch.Elapsed -lt $timeout) {
                $vm = Get-VM -Name $name -ErrorAction Stop
                if ($vm.State -eq 'Off') {
                    break
                }

                Start-Sleep -Seconds 5
            }

            if (-not $vm -or $vm.State -ne 'Off') {
                throw "VM '$name' failed to reach the Off state within $RestartTimeoutMinutes minute(s)."
            }

            Write-Verbose "Starting VM $name"
            Start-VM -Name $name -ErrorAction Stop

            $stopwatch.Restart()
            while ($stopwatch.Elapsed -lt $timeout) {
                $vm = Get-VM -Name $name -ErrorAction Stop
                if ($vm.State -eq 'Running') {
                    break
                }

                Start-Sleep -Seconds 5
            }

            if (-not $vm -or $vm.State -ne 'Running') {
                throw "VM '$name' failed to reach the Running state within $RestartTimeoutMinutes minute(s)."
            }
        }
        catch {
            throw
        }
    }
}
