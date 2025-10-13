param(
    [string]$DotnetVersion = '9.0.100',
    [string]$DotnetInstallUri = 'https://dotnet.microsoft.com/download/dotnet/scripts/v1/dotnet-install.ps1',
    [string]$AzureCliInstallerUri = 'https://aka.ms/installazurecliwindows'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$DownloadHeaders = @{ 'User-Agent' = 'AzureDevOpsAgentBuilder/1.0' }

function Invoke-WingetInstall {
    param(
        [string]$Id
    )
    winget install --id $Id --exact --silent --accept-source-agreements --accept-package-agreements --force
}

function Install-DotnetFallback {
    $scriptPath = Join-Path $env:TEMP 'dotnet-install.ps1'
    Invoke-WithRetry -Description 'Download dotnet-install.ps1' -Action {
        Write-Host 'Downloading dotnet-install.ps1...'
        Invoke-WebRequest -Uri $DotnetInstallUri -OutFile $scriptPath -UseBasicParsing -TimeoutSec 600 -Headers $DownloadHeaders
    }
    try {
        Write-Host 'Installing .NET SDK (fallback)...'
        $dotnetArgs = @('-Version', $DotnetVersion, '-InstallDir', 'C:\Program Files\dotnet')
        & powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath @dotnetArgs
        Write-Host '.NET SDK install completed.'
    }
    finally {
        if (Test-Path $scriptPath) { Remove-Item $scriptPath -Force }
    }
}

function Install-AzureCliFallback {
    $cliInstaller = Join-Path $env:TEMP 'AzureCLI.msi'
    Invoke-WithRetry -Description 'Download Azure CLI installer' -Action {
        Write-Host 'Downloading Azure CLI installer...'
        Invoke-WebRequest -Uri $AzureCliInstallerUri -OutFile $cliInstaller -UseBasicParsing -TimeoutSec 600 -Headers $DownloadHeaders
    }
    try {
        Write-Host 'Installing Azure CLI (fallback MSI)...'
        Start-Process -FilePath msiexec.exe -ArgumentList '/i', $cliInstaller, '/qn', '/norestart', '/log', (Join-Path $env:TEMP 'AzureCLI.log') -Wait
        Write-Host 'Azure CLI install completed.'
    }
    finally {
        if (Test-Path $cliInstaller) { Remove-Item $cliInstaller -Force }
    }
}

function Get-PowerShellInstallerInfo {
    param(
        [string]$Architecture = 'win-x64'
    )

    $apiUri = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
    try {
        Write-Host 'Querying GitHub API for latest PowerShell release...'
        $release = Invoke-RestMethod -Uri $apiUri -Headers $DownloadHeaders -TimeoutSec 60 -ErrorAction Stop
        if ($release -and $release.assets) {
            $asset = $release.assets | Where-Object { $_.name -match "PowerShell-.*-$Architecture\.msi$" } | Select-Object -First 1
            if ($asset) {
                return [ordered]@{ Version = $release.tag_name; Url = $asset.browser_download_url }
            }
        }
        Write-Warning 'PowerShell release assets not found; falling back to static download link.'
    }
    catch {
        Write-Warning ("Failed to query GitHub releases API: {0}" -f $_.Exception.Message)
    }

    return [ordered]@{ Version = 'stable'; Url = 'https://aka.ms/powershell-release?tag=stable' }
}

function Install-PowerShellFallback {
    $pwshInstaller = Join-Path $env:TEMP 'PowerShell.msi'
    $pwshLog = Join-Path $env:TEMP 'PowerShellInstall.log'
    $installerInfo = Get-PowerShellInstallerInfo -Architecture 'win-x64'
    $downloadUrl = $installerInfo.Url

    Invoke-WithRetry -Description 'Download PowerShell installer' -Action {
        Write-Host "Downloading PowerShell installer from $downloadUrl..."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $pwshInstaller -UseBasicParsing -TimeoutSec 600 -Headers $DownloadHeaders
    }

    try {
        $versionLabel = if ($installerInfo.Version) { $installerInfo.Version } else { 'unknown version' }
        Write-Host ("Installing PowerShell 7 (fallback MSI) version {0}..." -f $versionLabel)
        Start-Process -FilePath msiexec.exe -ArgumentList '/i', $pwshInstaller, '/qn', '/norestart', '/log', $pwshLog -Wait
        Write-Host 'PowerShell 7 install completed.'
    }
    finally {
        if (Test-Path $pwshInstaller) { Remove-Item $pwshInstaller -Force }
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [ScriptBlock]$Action,
        [int]$MaxAttempts = 3,
        [int]$SecondsBetweenAttempts = 5,
        [string]$Description = 'operation'
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            Write-Host ('{0} attempt {1}/{2}...' -f $Description, $attempt, $MaxAttempts)
            & $Action
            return
        }
        catch {
            if ($attempt -ge $MaxAttempts) { throw }
            Write-Warning ('{0} failed on attempt {1}/{2}: {3}' -f $Description, $attempt, $MaxAttempts, $_.Exception.Message)
            Start-Sleep -Seconds $SecondsBetweenAttempts
        }
    }
}

$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($winget) {
    try { winget source update --quiet } catch { Write-Warning ('winget source update failed: {0}' -f $_.Exception.Message) }
    try { Invoke-WingetInstall -Id 'Microsoft.DotNet.SDK.9' } catch { Write-Warning ('winget install for .NET SDK failed: {0}' -f $_.Exception.Message); Install-DotnetFallback }
    try { Invoke-WingetInstall -Id 'Microsoft.AzureCLI' } catch { Write-Warning ('winget install for Azure CLI failed: {0}' -f $_.Exception.Message); Install-AzureCliFallback }
    try { Invoke-WingetInstall -Id 'Microsoft.PowerShell' } catch { Write-Warning ('winget install for PowerShell failed: {0}' -f $_.Exception.Message); Install-PowerShellFallback }
}
else {
    Install-DotnetFallback
    Install-AzureCliFallback
    Install-PowerShellFallback
}

$dotnetPath = 'C:\Program Files\dotnet'
if (-not (Test-Path $dotnetPath)) {
    throw 'Expected dotnet installation directory not found.'
}

$azCliPath = Get-Command az -ErrorAction SilentlyContinue
if (-not $azCliPath) {
    $defaultCliPath = 'C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin'
    if (Test-Path $defaultCliPath) {
        $env:PATH = $defaultCliPath + ';' + $env:PATH
    }
    $azCliPath = Get-Command az -ErrorAction SilentlyContinue
}
if (-not $azCliPath) {
    throw 'Azure CLI executable not detected after installation.'
}

if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
    $pwshPath = 'C:\Program Files\PowerShell\7'
    $pwshExe = Join-Path $pwshPath 'pwsh.exe'
    if (Test-Path $pwshExe) {
        $env:PATH = $pwshPath + ';' + $env:PATH
    }
    if (-not (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        throw 'PowerShell 7 executable not detected after installation.'
    }
}

az config set extension.use_dynamic_install=yes_without_prompt | Out-Null
$hasAzDoExtension = $false
try {
    az extension show --name azure-devops --only-show-errors 1>$null 2>$null
    if ($LASTEXITCODE -eq 0) {
        $hasAzDoExtension = $true
    }
}
catch {
    Write-Verbose ('azure-devops extension not currently installed: {0}' -f $_.Exception.Message)
}
if (-not $hasAzDoExtension) {
    az extension add --name azure-devops --only-show-errors --yes
}

Write-Host '.NET SDK 9, PowerShell 7, and Azure CLI with azure-devops extension installed.'
