Set-StrictMode -Version Latest

function Install-DockerOnWindowsNodes {
    param(
        [Parameter()][string]$KubeConfigPath,
        [Parameter()][string]$Namespace = 'kube-system',
        [Parameter()][int]$TimeoutSeconds = 900
    )

    $kubectlCmd = Get-Command kubectl -ErrorAction SilentlyContinue
    if (-not $kubectlCmd) {
        Write-Warning 'kubectl CLI not found; skipping Docker installation on Windows nodes.'
        return @()
    }

    function Invoke-MobyLinkPreflight {
        param([string]$Url)

        Write-Host ("Preflight: validating download URL {0}" -f $Url)
        $statusCode = $null
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -Method Head -MaximumRedirection 5 -ErrorAction Stop
            $statusCode = $response.StatusCode
        }
        catch {
            $responseException = $_.Exception
            $webResponse = $responseException.Response
            if ($webResponse -and $webResponse.StatusCode.value__ -eq 405) {
                $tempFile = [System.IO.Path]::GetTempFileName()
                try {
                    $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -MaximumRedirection 5 -OutFile $tempFile -ErrorAction Stop
                    $statusCode = $response.StatusCode
                }
                finally {
                    Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
                }
            }
            else {
                throw ("Preflight download check failed for {0}: {1}" -f $Url, $responseException.Message)
            }
        }

        if (-not $statusCode) {
            throw "Preflight download check returned no status code for $Url."
        }
        if ($statusCode -lt 200 -or $statusCode -ge 400) {
            throw ("Preflight download check for {0} returned HTTP {1}." -f $Url, $statusCode)
        }
        Write-Host ("Preflight: {0} reachable (HTTP {1})." -f $Url, $statusCode)
    }

    $fallbackDownloadUrls = @(
        'https://aka.ms/moby-engine/windows2025'
        'https://aka.ms/moby-cli/windows2025'
        'https://aka.ms/moby-engine/windows2022'
        'https://aka.ms/moby-cli/windows2022'
        'https://aka.ms/moby-engine/windows2019'
        'https://aka.ms/moby-cli/windows2019'
        'https://aka.ms/moby-engine/windows2016'
        'https://aka.ms/moby-cli/windows2016'
        'https://raw.githubusercontent.com/microsoft/Windows-Containers/refs/heads/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1'
    ) | Sort-Object -Unique

    foreach ($url in $fallbackDownloadUrls) {
        Invoke-MobyLinkPreflight -Url $url
    }

    $kubectlArgs = @()
    if ($KubeConfigPath -and (Test-Path -LiteralPath $KubeConfigPath)) {
        $kubectlArgs += '--kubeconfig'
        $kubectlArgs += $KubeConfigPath
    }
    elseif ($KubeConfigPath) {
        Write-Warning "Specified kubeconfig path '$KubeConfigPath' not found. Using current kubectl context."
    }

    $nodeQuery = & $kubectlCmd.Path @kubectlArgs get nodes -l 'kubernetes.io/os=windows' -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning ("Failed to query Windows nodes via kubectl. Output:`n{0}" -f ($nodeQuery | Out-String))
        return @()
    }

    $nodeJson = $nodeQuery | Out-String
    if ([string]::IsNullOrWhiteSpace($nodeJson)) {
        Write-Host 'No Windows nodes returned from kubectl; skipping Docker installation.'
        return @()
    }

    try {
        $nodeObject = $nodeJson | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning ("Unable to parse kubectl nodes JSON: {0}" -f $_.Exception.Message)
        return @()
    }

    if (-not $nodeObject.items -or $nodeObject.items.Count -eq 0) {
        Write-Host 'No Windows nodes detected; skipping Docker installation.'
        return @()
    }

    $processedNodes = New-Object System.Collections.Generic.List[string]

    $installScript = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$transcriptPath = $null
$transcriptStarted = $false
try {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $transcriptRoot = 'C:\ProgramData\docker-installer'
    try {
        $transcriptDirectory = [System.IO.Directory]::CreateDirectory($transcriptRoot)
        $transcriptPath = Join-Path $transcriptDirectory.FullName ('docker-installer-transcript-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
        Start-Transcript -Path $transcriptPath -IncludeInvocationHeader -Force | Out-Null
        $transcriptStarted = $true
        Write-Host ("[docker-installer] Transcript active at {0}" -f $transcriptPath)
    }
    catch {
        Write-Host ("[docker-installer] Failed to start transcript in '{0}': {1}" -f $transcriptRoot, $_.Exception.Message)
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host '[docker-installer] DEBUG: after security protocol setup'
    $logPath = $null
    $logRoot = $null
$logRootCandidates = @(
    'C:\k\docker-installer',
    'C:\ProgramData\docker-installer',
    'C:\Packages\docker-installer',
    'C:\Windows\Temp\docker-installer',
    (Join-Path $env:TEMP 'docker-installer')
)
Write-Host ('[docker-installer] DEBUG: log root candidate count {0}' -f $logRootCandidates.Count)
$logInitDiagnostics = [System.Collections.Generic.List[object]]::new()
foreach ($candidate in $logRootCandidates) {
    $diag = [pscustomobject]@{ Path = $candidate; Created = $false; Error = $null }
    try {
        $dirInfo = [System.IO.Directory]::CreateDirectory($candidate)
        $diag.Created = $dirInfo.FullName -eq $candidate
        if ([System.IO.Directory]::Exists($candidate)) {
            $logRoot = $candidate
            $logPath = Join-Path $logRoot ('docker-installer-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
            Write-Host ("[docker-installer] Logging to {0}" -f $logPath)
            $logInitDiagnostics.Add($diag)
            break
        }
    }
    catch {
        $diag.Error = $_.Exception.Message
        Write-Host ("[docker-installer] Failed to initialize log directory '{0}': {1}" -f $candidate, $_.Exception.Message)
    }
    $logInitDiagnostics.Add($diag)
}
Write-Host ('[docker-installer] DEBUG: log init diagnostics entries {0}' -f $logInitDiagnostics.Count)
if (-not $logPath) {
    Write-Host ("[docker-installer] Log directory creation attempts: {0}" -f (($logInitDiagnostics | ConvertTo-Json -Depth 3 -Compress)))
    if ($transcriptStarted -and $transcriptPath) {
        try {
            $fallbackDir = Split-Path -Path $transcriptPath -Parent
            if ($fallbackDir) {
                if (-not (Test-Path -LiteralPath $fallbackDir)) {
                    [System.IO.Directory]::CreateDirectory($fallbackDir) | Out-Null
                }
                $logRoot = $fallbackDir
                $logPath = Join-Path $fallbackDir ('docker-installer-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
                Write-Host ("[docker-installer] Falling back to transcript directory for log file: {0}" -f $logPath)
            }
        }
        catch {
            Write-Host ("[docker-installer] Fallback log path initialization failed: {0}" -f $_.Exception.Message)
        }
    }
}
function Write-InstallerLog {
    param([string]$Message)
    $timestamp = Get-Date -Format 's'
    $prefixed = "[docker-installer] $timestamp $Message"
    Write-Host $prefixed
    if ($logPath) {
        try { Add-Content -LiteralPath $logPath -Value $prefixed -Encoding utf8 }
        catch { }
    }
}
if ($logPath) {
    Write-InstallerLog ("Installer log file: {0}" -f $logPath)
}
else {
    Write-Host "[docker-installer] Persistent log directory unavailable; continuing without file logging."
}
Write-Host '[docker-installer] DEBUG: completed log initialization'
function Get-DockerService {
    foreach ($candidate in @('docker','com.docker.service','moby-engine')) {
        $svc = Get-Service -Name $candidate -ErrorAction SilentlyContinue
        if ($svc) { return $svc }
    }
    return $null
}
function Get-MobyDownloadUrls {
    $default = @{ Engine = 'https://aka.ms/moby-engine/windows2022'; Cli = 'https://aka.ms/moby-cli/windows2022' }
    try {
        $osInfo = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $buildNumber = [int]$osInfo.CurrentBuild
    }
    catch {
        Write-InstallerLog ("Failed to resolve Windows build number. Defaulting to 2022 packages. Error: {0}" -f $_.Exception.Message)
        return $default
    }
    if ($buildNumber -ge 26100) {
        return @{ Engine = 'https://aka.ms/moby-engine/windows2025'; Cli = 'https://aka.ms/moby-cli/windows2025' }
    }
    elseif ($buildNumber -ge 20348) {
        return @{ Engine = 'https://aka.ms/moby-engine/windows2022'; Cli = 'https://aka.ms/moby-cli/windows2022' }
    }
    elseif ($buildNumber -ge 17763) {
        return @{ Engine = 'https://aka.ms/moby-engine/windows2019'; Cli = 'https://aka.ms/moby-cli/windows2019' }
    }
    else {
        return @{ Engine = 'https://aka.ms/moby-engine/windows2016'; Cli = 'https://aka.ms/moby-cli/windows2016' }
    }
}
function Install-MobyCliPackage {
    param([hashtable]$MobyUrls)

    if (-not $MobyUrls) { $MobyUrls = Get-MobyDownloadUrls }
    $cliArchivePath = Join-Path $env:TEMP ("moby-cli-" + [Guid]::NewGuid().ToString('N') + '.zip')
    $cliExtractPath = Join-Path $env:TEMP ("moby-cli-" + [Guid]::NewGuid().ToString('N'))
    try {
        Write-InstallerLog ("Downloading Docker CLI archive from {0}" -f $MobyUrls.Cli)
        Invoke-WebRequest -Uri $MobyUrls.Cli -OutFile $cliArchivePath -UseBasicParsing -ErrorAction Stop
        if (Test-Path -LiteralPath $cliExtractPath) {
            Remove-Item -LiteralPath $cliExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $cliExtractPath -Force | Out-Null
        if (Get-Command -Name Expand-Archive -ErrorAction SilentlyContinue) {
            Expand-Archive -LiteralPath $cliArchivePath -DestinationPath $cliExtractPath -Force
        }
        else {
            if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.FullName -match 'System.IO.Compression.FileSystem' })) {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            }
            [System.IO.Compression.ZipFile]::ExtractToDirectory($cliArchivePath, $cliExtractPath)
        }
        $targetRoot = 'C:\Program Files\Docker'
        if (-not (Test-Path -LiteralPath $targetRoot)) {
            New-Item -ItemType Directory -Path $targetRoot -Force | Out-Null
        }
        Get-ChildItem -LiteralPath $cliExtractPath -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($cliExtractPath.Length).TrimStart('\\')
            $destination = Join-Path $targetRoot $relative
            $destinationDir = Split-Path -Path $destination -Parent
            if (-not (Test-Path -LiteralPath $destinationDir)) {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            }
            Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
        }
        Write-InstallerLog ("Installed Docker CLI binaries into {0}" -f $targetRoot)
    }
    finally {
        foreach ($path in @($cliArchivePath, $cliExtractPath)) {
            if ($path -and (Test-Path -LiteralPath $path)) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
function Ensure-DockerCliPresent {
    param([hashtable]$MobyUrls)

    $candidatePaths = @(
        'C:\Program Files\Docker\Docker\resources\bin\docker.exe'
        'C:\Program Files\Docker\docker.exe'
        'C:\Program Files\docker\docker.exe'
        'C:\Program Files\moby\docker.exe'
        'C:\Windows\System32\docker.exe'
        'C:\Windows\docker.exe'
        'C:\docker\docker.exe'
    )
    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    Write-InstallerLog 'Docker CLI not detected on host; attempting to download CLI package.'
    try {
        Install-MobyCliPackage -MobyUrls $MobyUrls
    }
    catch {
        Write-InstallerLog ("Unable to install Docker CLI package: {0}" -f $_.Exception.Message)
        return $null
    }
    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}
function Ensure-DockerBuildxPlugin {
    param(
        [string]$Version = 'v0.15.1',
        [string[]]$InstallRoots = @('C:\Program Files\Docker', 'C:\ProgramData\docker')
    )

    if ($InstallRoots) {
        Write-InstallerLog ("Docker buildx install roots: {0}" -f ($InstallRoots -join '; '))
    }
    $targetDirectories = @()
    foreach ($root in $InstallRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $targetDirectories += (Join-Path $root 'cli-plugins')
    }
    $targetDirectories += 'C:\Program Files\Docker\Docker\resources\cli-plugins'
    $targetDirectories = $targetDirectories | Where-Object { $_ } | Select-Object -Unique

    if ($targetDirectories) {
        Write-InstallerLog ("Docker buildx target directories: {0}" -f ($targetDirectories -join '; '))
    }

    $candidatePaths = $targetDirectories | ForEach-Object { Join-Path $_ 'docker-buildx.exe' }
    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate) {
            Write-InstallerLog ("Docker buildx plugin already present at {0}" -f $candidate)
            return $candidate
        }
    }

    $downloadUrl = "https://github.com/docker/buildx/releases/download/$Version/buildx-$Version.windows-amd64.exe"
    Write-InstallerLog ("Docker buildx plugin not found; downloading from {0}" -f $downloadUrl)
    $tempFile = Join-Path $env:TEMP ("docker-buildx-" + [Guid]::NewGuid().ToString('N') + '.exe')

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempFile -UseBasicParsing -ErrorAction Stop
        $installedPath = $null
        foreach ($directory in $targetDirectories) {
            if ([string]::IsNullOrWhiteSpace($directory)) { continue }
            try {
                if (-not (Test-Path -LiteralPath $directory)) {
                    New-Item -ItemType Directory -Path $directory -Force | Out-Null
                }
                Write-InstallerLog ("Staging docker buildx plugin into {0}" -f $directory)
                $destination = Join-Path $directory 'docker-buildx.exe'
                Copy-Item -LiteralPath $tempFile -Destination $destination -Force
                if (-not $installedPath) {
                    $installedPath = $destination
                }
                else {
                    Write-InstallerLog ("Additional docker buildx staging completed at {0}" -f $destination)
                }
            }
            catch {
                Write-InstallerLog ("Failed to stage docker buildx plugin into {0}: {1}" -f $directory, $_.Exception.Message)
            }
        }

        if (-not $installedPath) {
            throw 'Unable to install Docker buildx plugin into any target directory.'
        }

        Write-InstallerLog ("Docker buildx plugin installed at {0}" -f $installedPath)
        return $installedPath
    }
    catch {
        Write-InstallerLog ("Docker buildx plugin installation failed: {0}" -f $_.Exception.Message)
        throw
    }
    finally {
        if (Test-Path -LiteralPath $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}
function Get-DockerdCandidatePaths {
    return @(
        'C:\Program Files\Docker\Docker\resources\dockerd.exe'
        'C:\Program Files\Docker\dockerd.exe'
        'C:\Program Files\Docker\cli\dockerd.exe'
        'C:\Program Files\Docker\moby-cli\dockerd.exe'
        'C:\Program Files\docker\dockerd.exe'
        'C:\Program Files\moby\dockerd.exe'
        'C:\Windows\System32\dockerd.exe'
    )
}
function Ensure-DockerdServiceRegistered {
    param([hashtable]$MobyUrls)

    $service = Get-DockerService
    if ($service) { return $service }

    foreach ($dockerdPath in Get-DockerdCandidatePaths()) {
        if (-not $dockerdPath) { continue }
        if (Test-Path -LiteralPath $dockerdPath) {
            Write-InstallerLog ("Attempting to register docker service using {0}" -f $dockerdPath)
            try {
                & $dockerdPath --register-service 2>&1 | Out-Null
            }
            catch {
                Write-InstallerLog ("dockerd --register-service failed: {0}" -f $_.Exception.Message)
            }
        }
    }

    $service = Get-DockerService
    if ($service) { return $service }

    Write-InstallerLog 'Docker service still not found; invoking helper script as a last resort.'
    $helperSuccess = Install-DockerViaHelperScript
    if ($helperSuccess) {
        $service = Get-DockerService
        if ($service) { return $service }
        Write-InstallerLog 'Helper script completed but docker service is still absent.'
    }

    return $null
}
function Test-IsZipFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $buffer = New-Object byte[] 4
            $read = $fs.Read($buffer, 0, 4)
            if ($read -eq 4 -and $buffer[0] -eq 0x50 -and $buffer[1] -eq 0x4B -and $buffer[2] -eq 0x03 -and $buffer[3] -eq 0x04) {
                return $true
            }
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        return $false
    }
    return $false
}
function Ensure-WindowsContainersFeature {
    Write-InstallerLog 'Ensuring Windows Containers feature is enabled.'
    $featureEnabled = $false
    try {
        $optionalFeature = Get-WindowsOptionalFeature -Online -FeatureName 'Containers' -ErrorAction Stop
        if ($optionalFeature.State -eq 'Enabled') {
            Write-InstallerLog 'Windows Containers optional feature already enabled.'
            $featureEnabled = $true
        }
        else {
            Write-InstallerLog 'Enabling Windows Containers optional feature via DISM.'
            Enable-WindowsOptionalFeature -Online -FeatureName 'Containers' -All -NoRestart -ErrorAction Stop | Out-Null
            $featureEnabled = $true
        }
    }
    catch {
        Write-InstallerLog ("DISM optional feature path failed: {0}" -f $_.Exception.Message)
    }

    if (-not $featureEnabled) {
        try {
            if (-not (Get-Module -ListAvailable -Name ServerManager)) {
                Import-Module ServerManager -ErrorAction Stop | Out-Null
            }
            $serverFeature = Get-WindowsFeature -Name Containers -ErrorAction Stop
            if ($serverFeature -and $serverFeature.Installed) {
                Write-InstallerLog 'Windows Containers feature already installed via ServerManager.'
                $featureEnabled = $true
            }
            else {
                Write-InstallerLog 'Installing Windows Containers feature via ServerManager.'
                Install-WindowsFeature -Name Containers -ErrorAction Stop | Out-Null
                $featureEnabled = $true
            }
        }
        catch {
            Write-InstallerLog ("ServerManager feature path failed: {0}" -f $_.Exception.Message)
        }
    }

    if (-not $featureEnabled) {
        throw 'Unable to enable Windows Containers feature. Install it manually and rerun the installer.'
    }
}
function Install-DockerViaHelperScript {
    param([string]$ScriptUrl = 'https://raw.githubusercontent.com/microsoft/Windows-Containers/refs/heads/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1')

    Write-InstallerLog ("Attempting Docker installation via helper script: {0}" -f $ScriptUrl)
    $scriptPath = Join-Path $env:TEMP ('install-docker-ce-' + [Guid]::NewGuid().ToString('N') + '.ps1')
    try {
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $scriptPath -UseBasicParsing -ErrorAction Stop
        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath)
        $process = Start-Process powershell.exe -ArgumentList $arguments -Wait -NoNewWindow -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Helper script exited with code $($process.ExitCode)"
        }
        Write-InstallerLog 'Helper script completed successfully.'
        return $true
    }
    catch {
        Write-InstallerLog ("Helper script installation failed: {0}" -f $_.Exception.Message)
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $scriptPath) {
            Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}
function Install-MsiFromPackage {
    param(
        [Parameter(Mandatory=$true)][string]$PackagePath,
        [Parameter(Mandatory=$true)][string]$DisplayName
    )

    if (Test-IsZipFile -Path $PackagePath) {
        Write-InstallerLog ("{0} package detected as ZIP archive. Extracting before install." -f $DisplayName)
        $extractRoot = Join-Path $env:TEMP ("{0}-extract-" -f $DisplayName.Replace(' ', '').ToLower())
        if (Test-Path -LiteralPath $extractRoot) {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
        try {
            if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.FullName -match 'System.IO.Compression.FileSystem' })) {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            }
            [System.IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $extractRoot)
            $msi = Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter '*.msi' | Select-Object -First 1
            if (-not $msi) {
                throw "No MSI found inside archive for $DisplayName"
            }
            $logPath = Join-Path $env:TEMP (("{0}-install" -f $DisplayName.Replace(' ', '-')) + '-' + [Guid]::NewGuid().ToString('N') + '.log')
            $process = Start-Process msiexec.exe -ArgumentList "/i `"$($msi.FullName)`" /qn /norestart /l*v `"$logPath`"" -Wait -NoNewWindow -PassThru
            if ($process.ExitCode -ne 0) {
                throw "$DisplayName MSI exited with code $($process.ExitCode). See $logPath for details"
            }
            if (Test-Path -LiteralPath $logPath) {
                Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
            }
        }
        finally {
            if (Test-Path -LiteralPath $extractRoot) {
                Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    else {
        $logPath = Join-Path $env:TEMP (("{0}-install" -f $DisplayName.Replace(' ', '-')) + '-' + [Guid]::NewGuid().ToString('N') + '.log')
        $process = Start-Process msiexec.exe -ArgumentList "/i `"$PackagePath`" /qn /norestart /l*v `"$logPath`"" -Wait -NoNewWindow -PassThru
        if ($process.ExitCode -ne 0) {
            throw "$DisplayName MSI exited with code $($process.ExitCode). See $logPath for details"
        }
        if (Test-Path -LiteralPath $logPath) {
            Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        }
    }
}
Write-InstallerLog "Checking for existing Docker service..."
$mobyUrls = $null
$dockerService = Get-DockerService
if ($dockerService) {
    Write-InstallerLog ("Docker service already present (status: {0}). Ensuring startup." -f $dockerService.Status)
    try {
        Set-Service -Name $dockerService.Name -StartupType Automatic -ErrorAction Stop
        if ($dockerService.Status -ne 'Running') {
            Start-Service -Name $dockerService.Name -ErrorAction Stop
        }
    }
    catch {
        Write-InstallerLog ("Failed to ensure docker service startup: {0}" -f $_.Exception.Message)
        throw
    }
}
else {
    try {
        Ensure-WindowsContainersFeature
    }
    catch {
        Write-InstallerLog ("Failed to ensure Windows Containers feature prerequisites: {0}" -f $_.Exception.Message)
        throw
    }

    Write-InstallerLog 'Installing DockerMsftProvider components...'
    $mobyUrls = Get-MobyDownloadUrls
    try {
        if (Get-Command -Name Set-PSRepository -ErrorAction SilentlyContinue) {
            $repo = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
            if ($repo -and $repo.InstallationPolicy -ne 'Trusted') {
                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }
    catch {
        Write-InstallerLog ("Failed to configure PSGallery trust: {0}" -f $_.Exception.Message)
    }
    if (-not (Get-PackageProvider -Name 'NuGet' -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }
    if (-not (Get-Module -ListAvailable -Name DockerMsftProvider)) {
        Install-Module -Name DockerMsftProvider -Repository PSGallery -Force -AllowClobber -ErrorAction Stop
    }
    $dockerInstallSucceeded = $false
    foreach ($packageName in @('docker','moby')) {
        try {
            Write-InstallerLog ("Attempting Install-Package via DockerMsftProvider for '{0}'" -f $packageName)
            Install-Package -Name $packageName -ProviderName DockerMsftProvider -Force -ForceBootstrap -ErrorAction Stop | Out-Null
            Write-InstallerLog ("Install-Package '{0}' completed successfully." -f $packageName)
            $dockerInstallSucceeded = $true
            break
        }
        catch {
            Write-InstallerLog ("Install-Package '{0}' failed: {1}" -f $packageName, $_.Exception.Message)
        }
    }
    if (-not $dockerInstallSucceeded) {
        $enginePath = Join-Path $env:TEMP 'moby-engine.pkg'
        try {
            Write-InstallerLog ("Falling back to Moby engine download from {0}" -f $mobyUrls.Engine)
            Invoke-WebRequest -Uri $mobyUrls.Engine -OutFile $enginePath -UseBasicParsing -ErrorAction Stop
            Install-MsiFromPackage -PackagePath $enginePath -DisplayName 'Moby engine'
            Install-MobyCliPackage -MobyUrls $mobyUrls
            Write-InstallerLog 'Moby engine and CLI artifacts installed from fallback packages.'
            $dockerInstallSucceeded = $true
        }
        catch {
            Write-InstallerLog ("Fallback Moby installation failed: {0}" -f $_.Exception.Message)
            $helperSuccess = Install-DockerViaHelperScript
            if ($helperSuccess) {
                Write-InstallerLog 'Docker installed via helper script.'
                $dockerInstallSucceeded = $true
            }
            else {
                throw 'Docker installation failed via DockerMsftProvider, fallback packages, and helper script.'
            }
        }
        finally {
            if (Test-Path $enginePath) {
                Remove-Item $enginePath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Start-Sleep -Seconds 5
    $dockerService = Ensure-DockerdServiceRegistered -MobyUrls $mobyUrls
    if (-not $dockerService) {
        throw 'Docker service not found after installation.'
    }
    Set-Service -Name $dockerService.Name -StartupType Automatic -ErrorAction SilentlyContinue
    if ($dockerService.Status -ne 'Running') {
        try { Start-Service -Name $dockerService.Name -ErrorAction SilentlyContinue | Out-Null }
        catch { Write-InstallerLog ("Failed to start docker service: {0}" -f $_.Exception.Message) }
        Start-Sleep -Seconds 3
    }
}
if (-not $mobyUrls) {
    try {
        $mobyUrls = Get-MobyDownloadUrls
    }
    catch {
        $mobyUrls = $null
        Write-InstallerLog ("Failed to resolve Moby download URLs post-install: {0}" -f $_.Exception.Message)
    }
}
$cliResolvedPath = Ensure-DockerCliPresent -MobyUrls $mobyUrls
if ($cliResolvedPath) {
    Write-InstallerLog ("Docker CLI located at {0}" -f $cliResolvedPath)
}
else {
    Write-InstallerLog 'Docker CLI could not be located after installation attempts.'
}
$cliSources = @()
if ($cliResolvedPath) {
    $cliSources += (Split-Path -Path $cliResolvedPath -Parent)
}
$cliSources += @(
    'C:\Program Files\Docker\Docker\resources\bin'
    'C:\Program Files\Docker'
    'C:\Program Files\docker'
    'C:\Program Files\moby'
)
$cliSources = $cliSources | Where-Object { $_ } | Select-Object -Unique
$cliSource = $cliSources | Where-Object { Test-Path $_ } | Select-Object -First 1
$desktopBin = 'C:\Program Files\Docker\Docker\resources\bin'
if ($cliSource) {
    if (-not (Test-Path $desktopBin)) {
        New-Item -ItemType Directory -Path $desktopBin -Force | Out-Null
    }
    Get-ChildItem -Path $cliSource -Filter '*.exe' -Recurse | ForEach-Object {
        try {
            $target = Join-Path $desktopBin $_.Name
            if ($target -ieq $_.FullName) { return }
            Copy-Item $_.FullName -Destination $target -Force
        }
        catch {
            Write-InstallerLog ("Failed to mirror CLI binary {0}: {1}" -f $_.Name, $_.Exception.Message)
        }
    }
    $machinePath = [Environment]::GetEnvironmentVariable('PATH','Machine')
    if ($machinePath -and $machinePath -notmatch 'Docker\\Docker\\resources\\bin') {
        $newPath = $machinePath.TrimEnd(';') + ';' + $desktopBin
        [Environment]::SetEnvironmentVariable('PATH', $newPath, 'Machine')
        Write-InstallerLog 'Appended Docker Desktop resources bin to machine PATH.'
    }
}
else {
    Write-InstallerLog 'Failed to locate Docker CLI source directory after installation.'
}
$buildxRoots = @('C:\Program Files\Docker', 'C:\ProgramData\docker')
if ($cliResolvedPath) {
    $cliDirectory = Split-Path -Path $cliResolvedPath -Parent
    if ($cliDirectory) {
        $buildxRoots += $cliDirectory
    }

    $currentDir = $cliDirectory
    while ($currentDir) {
        $leaf = Split-Path -Path $currentDir -Leaf
        if ($leaf -and $leaf.Equals('Docker', [StringComparison]::OrdinalIgnoreCase)) {
            $buildxRoots += $currentDir
            break
        }
        $parentDir = Split-Path -Path $currentDir -Parent
        if (-not $parentDir -or $parentDir -eq $currentDir) { break }
        $currentDir = $parentDir
    }
}
$buildxRoots = $buildxRoots | Where-Object { $_ } | Select-Object -Unique
$buildxVersion = 'v0.15.1'
$buildxPath = $null
try {
    $buildxPath = Ensure-DockerBuildxPlugin -Version $buildxVersion -InstallRoots $buildxRoots
}
catch {
    Write-InstallerLog ("Failed to ensure docker buildx plugin: {0}" -f $_.Exception.Message)
    throw
}
if ($buildxPath -and (Test-Path -LiteralPath $desktopBin)) {
    try {
        $desktopBuildxPath = Join-Path $desktopBin 'docker-buildx.exe'
        if (-not [string]::Equals($desktopBuildxPath, $buildxPath, [StringComparison]::OrdinalIgnoreCase)) {
            Copy-Item -LiteralPath $buildxPath -Destination $desktopBuildxPath -Force
        }
    }
    catch {
        Write-InstallerLog ("Failed to mirror docker buildx plugin into desktop bin: {0}" -f $_.Exception.Message)
    }
}
$finalService = Ensure-DockerdServiceRegistered -MobyUrls $mobyUrls
if (-not $finalService) {
    throw 'Docker service not available after installation attempt.'
}
Set-Service -Name $finalService.Name -StartupType Automatic -ErrorAction SilentlyContinue
if ($finalService.Status -ne 'Running') {
    try { Start-Service -Name $finalService.Name -ErrorAction SilentlyContinue | Out-Null }
    catch { Write-InstallerLog ("Failed to start docker service: {0}" -f $_.Exception.Message) }
    $finalService = Get-DockerService
}
Write-InstallerLog ("Docker installation complete. Service name: {0}; status: {1}" -f $finalService.Name, $finalService.Status)
if ($transcriptStarted) {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
        Write-Host ("[docker-installer] Failed to stop transcript gracefully: {0}" -f $_.Exception.Message)
    }
    finally {
        $transcriptStarted = $false
    }
}
exit 0
}
catch {
    $message = $_.Exception.Message
    if ([string]::IsNullOrWhiteSpace($message)) { $message = $_.ToString() }
    Write-Host '[docker-installer] DEBUG: entering catch block'
    Write-Host ("[docker-installer] Unhandled exception: {0}" -f $message)
    if ($_.Exception -and $_.Exception.StackTrace) {
        Write-Host ("[docker-installer] Exception stack: {0}" -f $_.Exception.StackTrace)
    }
    throw
}
finally {
    if ($transcriptStarted) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}
'@

    # Compress the installer payload to keep the encoded command well below the Win32 command-line limits
    $installScriptBytes = [System.Text.Encoding]::UTF8.GetBytes($installScript)
    $memoryStream = New-Object System.IO.MemoryStream
    try {
        $gzipStream = New-Object System.IO.Compression.GzipStream($memoryStream, [System.IO.Compression.CompressionMode]::Compress, $true)
        try {
            $gzipStream.Write($installScriptBytes, 0, $installScriptBytes.Length)
        }
        finally {
            $gzipStream.Dispose()
        }
        $compressedBytes = $memoryStream.ToArray()
    }
    finally {
        $memoryStream.Dispose()
    }

    $compressedInstallScript = [Convert]::ToBase64String($compressedBytes)
    $stubSegments = @(
        '$c="__PAYLOAD__";'
        '$b=[Convert]::FromBase64String($c);'
        '$m=[IO.MemoryStream]::new($b);'
        '$g=[IO.Compression.GzipStream]::new($m,[IO.Compression.CompressionMode]::Decompress);'
        '$r=[IO.StreamReader]::new($g,[Text.Encoding]::UTF8);'
        'try{$s=$r.ReadToEnd()}finally{$r.Dispose();$g.Dispose();$m.Dispose()};'
        '$p=Join-Path $env:TEMP ("install-docker-"+[Guid]::NewGuid().ToString("N")+".ps1");'
        'Set-Content -LiteralPath $p -Value $s -Encoding UTF8;'
        '$d="C:\\ProgramData\\docker-installer";'
        'try{[IO.Directory]::CreateDirectory($d)|Out-Null}catch{};'
        '$o=Join-Path $d ("docker-installer-hostoutput-"+(Get-Date -Format "yyyyMMdd-HHmmss")+".log");'
        '$e=0;'
        'try{powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $p *>&1|Tee-Object -FilePath $o;$e=$LASTEXITCODE}'
        'catch{$e=1;$m=$_.Exception.Message;try{Add-Content -LiteralPath $o -Value ("[stub] Exception: {0}" -f $m) -Encoding utf8}catch{};if($_.Exception.StackTrace){try{Add-Content -LiteralPath $o -Value ("[stub] Stack:`n{0}" -f $_.Exception.StackTrace) -Encoding utf8}catch{}}}'
        'finally{Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue};'
        'exit $e'
    )
    $stubTemplate = [string]::Concat($stubSegments)
    $stubScript = $stubTemplate.Replace('__PAYLOAD__', $compressedInstallScript)
    $inlineInstallCommand = "& { $stubScript }"
    $commandLiteralLines = @('      - |-')
    $chunkLength = 4000
    $safeBreakChars = [char[]]';'
    $offset = 0
    while ($offset -lt $inlineInstallCommand.Length) {
        $remaining = $inlineInstallCommand.Length - $offset
        if ($remaining -le $chunkLength) {
            $segment = $inlineInstallCommand.Substring($offset, $remaining)
            $offset = $inlineInstallCommand.Length
        }
        else {
            $window = $inlineInstallCommand.Substring($offset, $chunkLength)
            $breakIndex = $window.LastIndexOfAny($safeBreakChars)
            if ($breakIndex -lt 0) {
                $segment = $window
                $offset += $chunkLength
            }
            else {
                $segment = $window.Substring(0, $breakIndex + 1)
                $offset += ($breakIndex + 1)
            }
        }
        $commandLiteralLines += ('        ' + $segment)
    }
    $annotationKey = 'agents.cad4devops.dev/docker-installed'

    foreach ($node in $nodeObject.items) {
        if (-not $node -or -not $node.metadata -or [string]::IsNullOrWhiteSpace($node.metadata.name)) { continue }
        $nodeName = $node.metadata.name
        if ($nodeName -and -not $processedNodes.Contains($nodeName)) {
            [void]$processedNodes.Add($nodeName)
        }
        $annotationPresent = $false
        $annotationValue = $null
        if ($node.metadata.annotations) {
            $annotationProperty = $node.metadata.annotations.PSObject.Properties | Where-Object { $_.Name -eq $annotationKey }
            if ($annotationProperty) {
                $annotationPresent = $true
                $annotationValue = [string]$annotationProperty.Value
            }
        }
        if ($annotationPresent -and $annotationValue -eq 'true') {
            Write-Host "Node '$nodeName' already annotated with Docker installation. Running ensure step for verification." -ForegroundColor Yellow
        }

        $safeName = $nodeName.ToLowerInvariant() -replace '[^a-z0-9-]', '-'
        $safeName = $safeName.Trim('-')
        if ([string]::IsNullOrWhiteSpace($safeName)) {
            $safeName = "node-$([Math]::Abs($nodeName.GetHashCode()))"
        }
        if ($safeName.Length -gt 40) { $safeName = $safeName.Substring(0, 40) }
        $podName = "docker-installer-$safeName-" + ([Guid]::NewGuid().ToString('N').Substring(0, 6))
        $manifestPath = Join-Path ([System.IO.Path]::GetTempPath()) "$podName.yaml"

        # Host-process pods resolve binaries on the node filesystem, so use the absolute WindowsPowerShell path.
        $manifestLines = @(
            'apiVersion: v1'
            'kind: Pod'
            'metadata:'
            "  name: $podName"
            "  namespace: $Namespace"
            '  labels:'
            '    app: docker-installer'
            'spec:'
            "  nodeName: $nodeName"
            '  hostNetwork: true'
            '  dnsPolicy: ClusterFirstWithHostNet'
            '  securityContext:'
            '    windowsOptions:'
            '      hostProcess: true'
            "      runAsUserName: 'NT AUTHORITY\SYSTEM'"
            "      runAsUserName: 'NT AUTHORITY\SYSTEM'"
            '  tolerations:'
            '  - key: "sku"'
            '    operator: "Equal"'
            '    value: "Windows"'
            '    effect: "NoSchedule"'
            '  restartPolicy: Never'
            '  containers:'
            '  - name: installer'
            '    image: mcr.microsoft.com/powershell:lts-7.4-windowsservercore-ltsc2022'
            '    command:'
            '      - C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
            '    args:'
            '      - -NoLogo'
            '      - -NoProfile'
            '      - -Command'
        )
        $manifestLines += $commandLiteralLines
        $manifestLines += @(
            '    volumeMounts:'
            '    - name: docker-pipe'
            '      mountPath: "\\.\\pipe\\docker_engine"'
            '  volumes:'
            '  - name: docker-pipe'
            '    hostPath:'
            '      path: "\\.\\pipe\\docker_engine"'
        )
        $manifest = $manifestLines -join "`n"

        Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding ASCII
        Write-Host "Installing Docker Engine on Windows node '$nodeName' via host-process pod." -ForegroundColor Cyan

        $applyOutput = & $kubectlCmd.Path @kubectlArgs apply -f $manifestPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("Failed to create installer pod for node '{0}'. kubectl output:`n{1}" -f $nodeName, ($applyOutput | Out-String))
            if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
            continue
        }

        try {
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            $installSucceeded = $false
            while ((Get-Date) -lt $deadline) {
                $phaseOutput = & $kubectlCmd.Path @kubectlArgs get pod $podName -n $Namespace -o jsonpath='{.status.phase}' 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Start-Sleep -Seconds 5
                    continue
                }
                $phase = ($phaseOutput | Out-String).Trim()
                if ($phase -eq 'Succeeded') {
                    $installSucceeded = $true
                    break
                }
                if ($phase -eq 'Failed') {
                    $logs = & $kubectlCmd.Path @kubectlArgs logs $podName -n $Namespace 2>&1
                    $logText = ($logs | Out-String).Trim()
                    if ([string]::IsNullOrWhiteSpace($logText)) {
                        Write-Warning ("Docker installer pod on node '{0}' failed but produced no log output." -f $nodeName)
                    }
                    elseif ($logText -match "Cannot process the XML from the 'Output' stream") {
                        Write-Warning ("Docker installer pod on node '{0}' failed. kubectl could not decode the pod logs (likely UTF-16 output). Check the node's persistent logs under C:\\k\\docker-installer\\." -f $nodeName)
                    }
                    else {
                        Write-Warning ("Docker installer pod on node '{0}' failed. Logs:`n{1}" -f $nodeName, $logText)
                    }
                    $describe = & $kubectlCmd.Path @kubectlArgs describe pod $podName -n $Namespace 2>&1
                    Write-Warning ("kubectl describe pod output:`n{0}" -f ($describe | Out-String))
                    Write-Warning ('To inspect installer logs on node ''{0}'', run scripts\Debug-WindowsHost.ps1 -NodeName ''{0}'' -Command "Get-ChildItem ''C:\k\docker-installer'' | Sort-Object LastWriteTime"' -f $nodeName)
                    break
                }
                Start-Sleep -Seconds 5
            }

            if (-not $installSucceeded) {
                if ((Get-Date) -ge $deadline) {
                    Write-Warning 'Timed out waiting for Docker installer pod to complete.'
                }
                continue
            }

            $annotateOutput = & $kubectlCmd.Path @kubectlArgs annotate node $nodeName "$annotationKey=true" --overwrite 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning ("Failed to annotate node '{0}' after Docker installation. Output:`n{1}" -f $nodeName, ($annotateOutput | Out-String))
            }
            else {
                Write-Host "Docker installation completed on node '$nodeName'." -ForegroundColor Green
            }
        }
        finally {
            & $kubectlCmd.Path @kubectlArgs delete pod $podName -n $Namespace --ignore-not-found 2>&1 | Out-Null
            if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
        }
    }

    return $processedNodes.ToArray()
}

function Export-DockerInstallerLogs {
    param(
        [string[]]$NodeNames,
        [string]$KubeConfigPath,
        [string]$Namespace = 'kube-system',
        [string]$RepositoryRoot
    )

    if (-not $NodeNames -or $NodeNames.Count -eq 0) { return }

    $kubectlCmd = Get-Command kubectl -ErrorAction SilentlyContinue
    if (-not $kubectlCmd) {
        Write-Warning 'kubectl CLI not found; skipping Docker installer log collection.'
        return
    }

    $kubectlArgs = @()
    if ($KubeConfigPath -and (Test-Path -LiteralPath $KubeConfigPath)) {
        $kubectlArgs += '--kubeconfig'
        $kubectlArgs += $KubeConfigPath
    }
    elseif ($KubeConfigPath) {
        Write-Warning "Specified kubeconfig path '$KubeConfigPath' not found. Using current kubectl context for log collection."
    }

    if (-not $RepositoryRoot) {
        $repoPath = Resolve-Path (Join-Path $PSScriptRoot '..')
        $RepositoryRoot = $repoPath.ProviderPath
    }
    $logsFolder = Join-Path $RepositoryRoot 'logs'
    if (-not (Test-Path -LiteralPath $logsFolder)) {
        New-Item -ItemType Directory -Path $logsFolder -Force | Out-Null
    }

    $collectionTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFetchScript = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$locations = @(
    'C:\k\docker-installer',
    'C:\ProgramData\docker-installer',
    'C:\Packages\docker-installer',
    'C:\Windows\Temp\docker-installer',
    (Join-Path $env:TEMP 'docker-installer')
) | Select-Object -Unique
$files = @()
$diagnostics = @()
foreach ($loc in $locations) {
    $diag = [pscustomobject]@{
        Location = $loc
        Exists = $false
        CandidateCount = 0
        FilteredCount = 0
        Notes = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($loc) -and (Test-Path -LiteralPath $loc)) {
        $diag.Exists = $true
        $candidates = Get-ChildItem -LiteralPath $loc -File -Recurse -ErrorAction SilentlyContinue
        if ($candidates) {
            $diag.CandidateCount = $candidates.Count
            $filtered = $candidates | Where-Object {
                $_.Name -like 'docker-installer*.log' -or
                $_.Name -like 'install-docker*.log' -or
                $_.Name -like 'docker-*.log' -or
                $_.Name -like 'docker-*.txt' -or
                $_.Name -eq 'docker-installer.log'
            }
            if ($filtered) {
                $diag.FilteredCount = $filtered.Count
                $files += $filtered
            }
            elseif ($candidates.Count -le 20) {
                $diag.Notes = 'No pattern matches; returning all candidates.'
                $files += $candidates
            }
            else {
                $diag.Notes = 'No pattern matches; returning 5 most recent files.'
                $files += $candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 5
            }
        }
    }
    $diagnostics += $diag
}
$files = $files | Where-Object { $_ -and $_.PSObject.Properties.Match('FullName') } | Sort-Object LastWriteTimeUtc -Descending
$entries = @()
foreach ($file in $files) {
    try {
        $content = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop
    }
    catch {
        $diagnostics += [pscustomobject]@{
            Location = $file.FullName
            Stage = 'ReadContent'
            Error = $_.Exception.Message
        }
        continue
    }
    $entries += [pscustomobject]@{
        Path = $file.FullName
        LastWriteTimeUtc = $file.LastWriteTimeUtc
        ContentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
    }
}
[pscustomobject]@{
    Entries = $entries
    Diagnostics = $diagnostics
} | ConvertTo-Json -Depth 6 -Compress
'@
    $encodedLogFetch = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($logFetchScript))

    foreach ($nodeName in ($NodeNames | Sort-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($nodeName)) { continue }
        $safeNode = $nodeName.ToLowerInvariant() -replace '[^a-z0-9-]', '-'
        $safeNode = $safeNode.Trim('-')
        if ([string]::IsNullOrWhiteSpace($safeNode)) {
            $safeNode = "node-$([Math]::Abs($nodeName.GetHashCode()))"
        }
        if ($safeNode.Length -gt 40) { $safeNode = $safeNode.Substring(0, 40) }
        $podName = "docker-logfetch-$safeNode-" + ([Guid]::NewGuid().ToString('N').Substring(0, 6))
        $manifestPath = Join-Path ([System.IO.Path]::GetTempPath()) "$podName.yaml"

        $manifestLines = @(
            'apiVersion: v1'
            'kind: Pod'
            'metadata:'
            "  name: $podName"
            "  namespace: $Namespace"
            'spec:'
            "  nodeName: $nodeName"
            '  hostNetwork: true'
            '  dnsPolicy: ClusterFirstWithHostNet'
            '  securityContext:'
            '    windowsOptions:'
            '      hostProcess: true'
            "      runAsUserName: 'NT AUTHORITY\SYSTEM'"
            '  tolerations:'
            '  - key: "sku"'
            '    operator: "Equal"'
            '    value: "Windows"'
            '    effect: "NoSchedule"'
            '  restartPolicy: Never'
            '  containers:'
            '  - name: collector'
            '    image: mcr.microsoft.com/powershell:lts-7.4-windowsservercore-ltsc2022'
            '    command:'
            '      - C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
            '    args:'
            '      - -NoLogo'
            '      - -NoProfile'
            '      - -Command'
            '      - Start-Sleep -Seconds 600'
        )
        $manifest = $manifestLines -join "`n"

        Set-Content -LiteralPath $manifestPath -Value $manifest -Encoding ASCII

        $applyOutput = & $kubectlCmd.Path @kubectlArgs apply -f $manifestPath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("Failed to create log collector pod for node '{0}'. kubectl output:`n{1}" -f $nodeName, ($applyOutput | Out-String))
            if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
            continue
        }

        $podReady = $false
        try {
            $deadline = (Get-Date).AddSeconds(120)
            while ((Get-Date) -lt $deadline) {
                $phaseOutput = & $kubectlCmd.Path @kubectlArgs get pod $podName -n $Namespace -o jsonpath='{.status.phase}' 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Start-Sleep -Seconds 3
                    continue
                }
                $phase = ($phaseOutput | Out-String).Trim()
                if ($phase -eq 'Running') { $podReady = $true; break }
                if ($phase -eq 'Failed') {
                    Write-Warning ("Log collector pod for node '{0}' entered Failed phase." -f $nodeName)
                    break
                }
                Start-Sleep -Seconds 3
            }

            if (-not $podReady) {
                Write-Warning ("Log collector pod for node '{0}' did not reach Running state; skipping log capture." -f $nodeName)
                continue
            }

            $execOutput = & $kubectlCmd.Path @kubectlArgs exec $podName -n $Namespace -- powershell -NoLogo -NoProfile -EncodedCommand $encodedLogFetch 2>&1
            $execText = ($execOutput | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($execText)) {
                Write-Host ("No docker installer logs detected on node '{0}'." -f $nodeName)
                continue
            }

            try {
                $parsed = $execText | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                Write-Warning ("Failed to parse installer log JSON for node '{0}': {1}" -f $nodeName, $_.Exception.Message)
                continue
            }

            $entries = $null
            $diag = $null
            if ($parsed -and $parsed.PSObject -and $parsed.PSObject.Properties.Match('Entries')) {
                $entries = $parsed.Entries
                if ($parsed.PSObject.Properties.Match('Diagnostics')) {
                    $diag = $parsed.Diagnostics
                }
            }
            else {
                $entries = $parsed
            }

            if ($diag) {
                try {
                    $diagJson = ($diag | ConvertTo-Json -Depth 4 -Compress)
                    Write-Host ("Installer log diagnostics for node '{0}': {1}" -f $nodeName, $diagJson)
                }
                catch {
                    Write-Warning ("Failed to serialize diagnostics for node '{0}': {1}" -f $nodeName, $_.Exception.Message)
                }
            }

            if (-not $entries) {
                Write-Host ("Node '{0}' reported no docker installer log entries." -f $nodeName)
                continue
            }

            if ($entries -isnot [System.Collections.IEnumerable] -or $entries -is [string]) {
                $entries = @($entries)
            }

            foreach ($entry in $entries) {
                if (-not $entry) { continue }
                $remotePath = [string]$entry.Path
                $remoteName = if ($remotePath) { [System.IO.Path]::GetFileName($remotePath) } else { 'docker-installer.log' }
                $entryTimestamp = $collectionTimestamp
                if ($entry.PSObject.Properties.Match('LastWriteTimeUtc') -and $entry.LastWriteTimeUtc) {
                    try { $entryTimestamp = ([DateTime]::Parse($entry.LastWriteTimeUtc)).ToString('yyyyMMdd-HHmmss') }
                    catch { }
                }
                $contentBase64 = [string]$entry.ContentBase64
                if ([string]::IsNullOrWhiteSpace($contentBase64)) { continue }
                try {
                    $bytes = [Convert]::FromBase64String($contentBase64)
                }
                catch {
                    Write-Warning ("Failed to decode installer log content for node '{0}' ({1})." -f $nodeName, $remoteName)
                    continue
                }
                $destName = '{0}-{1}-{2}' -f $safeNode, $entryTimestamp, $remoteName
                $destPath = Join-Path $logsFolder $destName
                try {
                    [System.IO.File]::WriteAllBytes($destPath, $bytes)
                    Write-Host ("Saved Docker installer log for node '{0}' to {1}" -f $nodeName, $destPath)
                }
                catch {
                    Write-Warning ("Failed to write installer log to {0}: {1}" -f $destPath, $_.Exception.Message)
                }
            }
        }
        finally {
            & $kubectlCmd.Path @kubectlArgs delete pod $podName -n $Namespace --ignore-not-found 2>&1 | Out-Null
            if (Test-Path -LiteralPath $manifestPath) {
                Remove-Item -LiteralPath $manifestPath -Force 
            }
        }
    }
}
