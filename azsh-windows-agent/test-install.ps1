Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $PSCommandPath

# Ensure we are operating from the mounted workspace when inside container; otherwise fall back to script directory
if (Test-Path 'C:\workspace') {
    Set-Location 'C:\workspace'
}
else {
    Set-Location $scriptRoot
}

$installScript = Join-Path $scriptRoot 'Install-WindowsAgentTools.ps1'
if (-not (Test-Path $installScript)) {
    throw "Install-WindowsAgentTools.ps1 not found at expected path: $installScript"
}

Write-Host 'Running Install-WindowsAgentTools.ps1 -Verbose inside container...'
& $installScript -Verbose
Write-Host 'Install script completed.'

# Dump any MSI logs that were produced so debugging is easier when running interactively
if (Test-Path C:\workspace\*.log) {
    Get-ChildItem C:\workspace\*.log | ForEach-Object {
        Write-Host ("`n---- {0} ----" -f $_.Name)
        Get-Content $_
    }
}
else {
    Write-Host 'No *.log files found in workspace.'
}
