<#
.SYNOPSIS
    Builds and pushes Windows Azure DevOps agent Docker images to Azure Container Registry.

.DESCRIPTION
    This script builds Docker images for Windows-based Azure DevOps self-hosted agents and 
    pushes them to an Azure Container Registry (ACR). It supports multiple Windows versions
    (2019, 2022, 2025) and two build modes:
    
    1. PRE-BAKED (default): Downloads the Azure Pipelines agent at build time and includes it
       in the image. This results in faster agent startup times but larger images.
    
    2. STANDARD: The agent is downloaded at container runtime. This creates smaller images
       but has slower startup times.
    
    The script automatically:
    - Determines Windows versions to build from parameters or environment variables
    - Detects Hyper-V isolation support and falls back to process isolation if needed
    - Normalizes unqualified ACR names by appending .azurecr.io
    - Fetches the latest Azure Pipelines agent version if not specified (prebaked mode)
    - Creates multiple image tags including base, versioned, Windows-version-specific, and latest tags
    - Logs into ACR using Azure CLI
    - Pushes all tags to the registry with error handling
    - Captures and reports image digests for manifest list creation

.PARAMETER WindowsVersions
    Array of Windows versions to build (e.g., @('2019', '2022', '2025')).
    Defaults to @('2022', '2025'). Can be overridden by:
    1. Explicit -WindowsVersions parameter (highest priority)
    2. WIN_VERSION environment variable (single version)
    3. WINDOWS_VERSIONS environment variable (comma-separated)
    4. Default value (lowest priority)

.PARAMETER ContainerRegistryName
    The name or FQDN of the Azure Container Registry. If unqualified (no dots),
    '.azurecr.io' will be appended automatically. Can be set via ACR_NAME environment variable.
    Example: 'cragents003c66i4n7btfksg' or 'cragents003c66i4n7btfksg.azurecr.io'

.PARAMETER TagSuffix
    Optional suffix to append to tags, typically a date and commit SHA.
    Example: '20250920-a1b2c3d'. Can be set via TAG_SUFFIX environment variable.

.PARAMETER SemVer
    Semantic version to use as an additional tag (e.g., '1.0.0').
    Can be set via SEMVER_EFFECTIVE environment variable.

.PARAMETER DisableLatest
    If specified, the 'latest' tag will not be applied to the image.

.PARAMETER DefaultAcr
    Default ACR name to use when ContainerRegistryName is not provided.
    Example: 'cragents003c66i4n7btfksg'

.PARAMETER UsePrebaked
    Use the prebaked Dockerfile that includes the agent at build time (default: true).
    This is the recommended option for production as it provides faster agent startup.

.PARAMETER UseStandard
    Use the standard Dockerfile that downloads the agent at runtime.
    This overrides -UsePrebaked if both are specified.

.PARAMETER AgentVersion
    Specific Azure Pipelines agent version to use for prebaked images.
    If not specified, the latest version is fetched from GitHub releases.
    Example: '4.261.0'

.PARAMETER EnableHypervFallback
    If true (default), attempts to use Hyper-V isolation and falls back to process
    isolation if Hyper-V is not available. This allows the script to work on both
    Hyper-V enabled and non-Hyper-V hosts.

.EXAMPLE
    pwsh ./01-build-and-push.ps1 -DefaultAcr 'cragents003c66i4n7btfksg' -WindowsVersions @('2022')
    
    Builds and pushes a Windows Server 2022 prebaked agent image using the latest agent version.

.EXAMPLE
    pwsh ./01-build-and-push.ps1 -DefaultAcr 'myregistry' -WindowsVersions @('2019', '2022', '2025')
    
    Builds and pushes agent images for all three Windows versions.

.EXAMPLE
    $env:ACR_NAME = 'cragents003.azurecr.io'
    $env:WIN_VERSION = '2022'
    $env:TAG_SUFFIX = '20250920-a1b2c3d'
    pwsh ./01-build-and-push.ps1 -DefaultAcr 'fallback'
    
    Uses environment variables for configuration (common in CI pipelines).
    Builds only Windows Server 2022.

.EXAMPLE
    pwsh ./01-build-and-push.ps1 -DefaultAcr 'cragents003' -WindowsVersions @('2022') -UseStandard
    
    Builds a standard (runtime download) Windows agent image without Hyper-V isolation fallback.

.NOTES
    Prerequisites:
    - Docker must be installed and running with Windows containers enabled
    - Azure CLI (az) must be installed and authenticated
    - Current directory must be azsh-windows-agent/ containing the Dockerfiles
    - For Hyper-V isolation: Hyper-V feature must be enabled
    
    CI Usage:
    This script is designed to be called from Azure DevOps pipelines. The pipeline should:
    - Set environment variables (ACR_NAME, WIN_VERSION, TAG_SUFFIX, etc.)
    - Pass -WindowsVersions explicitly from pipeline tasks for clarity
    - Run per-version jobs to parallelize builds
    
    Isolation Modes:
    - Hyper-V isolation: Provides better security and compatibility across Windows versions
    - Process isolation: Faster but requires matching host/container OS versions
    
    Version Precedence (for determining which Windows versions to build):
    1. Explicit -WindowsVersions parameter (if provided by caller)
    2. Job-level WIN_VERSION environment variable (single version)
    3. Job-level WINDOWS_VERSIONS environment variable (CSV)
    4. Default parameter value @('2022', '2025')
    
    File: azsh-windows-agent/01-build-and-push.ps1
#>

param(
    [Parameter(Mandatory = $false)]
    [string[]]$WindowsVersions = @("2022", "2025"),
    [Parameter(Mandatory = $false)]
    [string]$ContainerRegistryName = $env:ACR_NAME,
    [Parameter(Mandatory = $false)]
    [string]$TagSuffix = $env:TAG_SUFFIX,
    [Parameter(Mandatory = $false)]
    [string]$SemVer = $env:SEMVER_EFFECTIVE,
    [Parameter(Mandatory = $false)]
    [switch]$DisableLatest,
    [Parameter(Mandatory = $false)]
    [string]$DefaultAcr,
    [Parameter(Mandatory = $false)]
    [switch]$UsePrebaked = $true,
    [Parameter(Mandatory = $false)]
    [switch]$UseStandard,
    [Parameter(Mandatory = $false)]
    [string]$AgentVersion,
    [Parameter(Mandatory = $false)]
    [switch]$EnableHypervFallback = $true
)

function Invoke-WindowsBuild {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$WindowsVersions = @("2022", "2025"),
        [Parameter(Mandatory = $false)]
        [string]$ContainerRegistryName = $env:ACR_NAME,
        [Parameter(Mandatory = $false)]
        [string]$TagSuffix = $env:TAG_SUFFIX,
        [Parameter(Mandatory = $false)]
        [string]$SemVer = $env:SEMVER_EFFECTIVE,
        [Parameter(Mandatory = $false)]
        [switch]$DisableLatest,
        [Parameter(Mandatory = $true)]
        [string]$DefaultAcr, #'cragents003c66i4n7btfksg'
        [Parameter(Mandatory = $false)]
        [switch]$UsePrebaked = $true,
        [Parameter(Mandatory = $false)]
        [switch]$UseStandard,
        [Parameter(Mandatory = $false)]
        [string]$AgentVersion,
        [Parameter(Mandatory = $false)]
        [switch]$EnableHypervFallback = $true
    )

    $ErrorActionPreference = 'Stop'
    # Reuse cross-platform green writer for CI-friendly logs
    function Write-Green([string]$msg) {
        try { if ($IsWindows) { Write-Host -ForegroundColor Green $msg } else { Write-Host "`e[32m$msg`e[0m" } } catch { Write-Host $msg }
    }

    function Test-HyperVIsolationSupport {
        $featureInstalled = $false
        $hypervisorPresent = $false

        if (Get-Command Get-WindowsFeature -ErrorAction SilentlyContinue) {
            try {
                $feature = Get-WindowsFeature -Name Hyper-V -ErrorAction Stop
                if ($feature -and $feature.InstallState -eq 'Installed') { $featureInstalled = $true }
            }
            catch { }
        }
        elseif (Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue) {
            try {
                $opt = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All -ErrorAction Stop
                if ($opt -and $opt.State -eq 'Enabled') { $featureInstalled = $true }
            }
            catch { }
        }

        try {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            if ($cs -and $cs.HypervisorPresent) { $hypervisorPresent = $true }
        }
        catch { }

        return ($featureInstalled -and $hypervisorPresent)
    }

    function Invoke-DockerBuildCommand {
        param(
            [Parameter(Mandatory)][string[]]$Arguments,
            [Parameter(Mandatory)][string]$FriendlyDescription
        )
        Write-Host ("Running docker {0}:`n  docker {1}" -f $FriendlyDescription, ($Arguments -join ' '))
        & docker @Arguments 2>&1 | ForEach-Object { Write-Host $_ }
        $exitCode = $LASTEXITCODE
        return [int]$exitCode
    }
    # Debug: print incoming environment and parameter state so CI logs show exact inputs
    Write-Host "[DEBUG] env:WIN_VERSION='$($env:WIN_VERSION)'; env:WINDOWS_VERSIONS='$($env:WINDOWS_VERSIONS)'"
    if ($PSBoundParameters.ContainsKey('WindowsVersions')) { Write-Host "[DEBUG] PSBoundParameters WindowsVersions: $($PSBoundParameters['WindowsVersions'] -join ',')" } else { Write-Host "[DEBUG] PSBoundParameters WindowsVersions: <not provided>" }
    # Determine effective Windows versions with clear precedence:
    # 1) Explicit -WindowsVersions parameter (if provided by caller)
    # 2) Job-level WIN_VERSION env var (single-version override)
    # 3) Job-level WINDOWS_VERSIONS env var
    # 4) Default parameter value (the script default)
    # Canonical default list string used to detect when the parameter contains the default
    $canonicalDefault = '2022,2025'

    # 1) WIN_VERSION env var absolute precedence
    if ($env:WIN_VERSION) {
        $WindowsVersions = @($env:WIN_VERSION.Trim())
        # canonicalize the WINDOWS_VERSIONS env var for any later readers
        $env:WINDOWS_VERSIONS = $WindowsVersions -join ','
        Write-Host "Using WIN_VERSION from environment as absolute override: $($WindowsVersions -join ',') (WINDOWS_VERSIONS set to $env:WINDOWS_VERSIONS)"
    }
    else {
        # 2) If the passed-in parameter is not the canonical default, treat it as an explicit request
        if ($WindowsVersions -and ($WindowsVersions -join ',') -ne $canonicalDefault) {
            Write-Host "Using WindowsVersions from explicit parameter: $($WindowsVersions -join ',')"
        }
        # 3) Otherwise, fall back to env WINDOWS_VERSIONS if present
        elseif ($env:WINDOWS_VERSIONS) {
            $parsed = $env:WINDOWS_VERSIONS.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            if ($parsed.Count -gt 0) {
                $WindowsVersions = $parsed
                Write-Host "Using WINDOWS_VERSIONS from environment: $($WindowsVersions -join ',')"
            }
        }
        else {
            # 4) keep the default parameter value
            Write-Host "Using default WindowsVersions: $($WindowsVersions -join ',')"
        }
    }
    # Resolve ContainerRegistryName: prefer provided parameter, then DEFAULT_ACR env var, then DefaultAcr fallback
    if (-not $ContainerRegistryName) {
        if ($env:DEFAULT_ACR) {
            $ContainerRegistryName = $env:DEFAULT_ACR
        }
        elseif ($DefaultAcr) {
            $ContainerRegistryName = $DefaultAcr
        }
        else {
            $ContainerRegistryName = 'cragents003c66i4n7btfksg'
        }
    }

    # If user supplied an unqualified registry name (no dot), assume Azure Container Registry and append the azurecr.io suffix
    if ($ContainerRegistryName -and ($ContainerRegistryName -notmatch '\.')) {
        Write-Host "ContainerRegistryName '$ContainerRegistryName' appears unqualified; appending '.azurecr.io' to form FQDN"
        $ContainerRegistryName = "$ContainerRegistryName.azurecr.io"
    }

    $acrShort = $ContainerRegistryName.Split('.')[0]

    # Determine build mode: UseStandard overrides default UsePrebaked
    if ($UseStandard) {
        $UsePrebaked = $false
        Write-Host "Using STANDARD agent Dockerfiles (agent downloaded at runtime)" -ForegroundColor Yellow
    }
    elseif ($UsePrebaked) {
        Write-Host "Using PRE-BAKED agent Dockerfiles (agent downloaded at build time)" -ForegroundColor Magenta
    }

    # Fetch latest agent version if not specified
    if ($UsePrebaked -and -not $AgentVersion) {
        try {
            Write-Host "Fetching latest Azure DevOps Agent version..." -ForegroundColor Cyan
            $latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/azure-pipelines-agent/releases/latest" -Headers @{ "User-Agent" = "PowerShell" }
            $AgentVersion = $latestRelease.tag_name -replace '^v', ''
            Write-Host "Latest agent version: $AgentVersion" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to fetch latest agent version, falling back to 4.261.0: $_"
            $AgentVersion = "4.261.0"
        }
    }

    # Log effective list of windows versions we will build
    Write-Host "Effective WindowsVersions: $($WindowsVersions -join ',')"
    if ($UsePrebaked) {
        Write-Host "Agent Version: $AgentVersion" -ForegroundColor Cyan
    }

    foreach ($windowsVersion in $WindowsVersions) {
        $baseTag = "windows-${windowsVersion}"
        $finalTag = if ($TagSuffix) { "$baseTag-$TagSuffix" } else { $baseTag }
        $repositoryName = "windows-sh-agent-${windowsVersion}"
        
        # Choose Dockerfile based on prebaked flag
        if ($UsePrebaked) {
            $dockerFileName = "./Dockerfile.${repositoryName}-windows${windowsVersion}.prebaked"
            Write-Host "Building PREBAKED Windows image ${repositoryName}:${finalTag} with agent v${AgentVersion}" -ForegroundColor Cyan
        }
        else {
            $dockerFileName = "./Dockerfile.${repositoryName}-windows${windowsVersion}"
            Write-Host "Building STANDARD Windows image ${repositoryName}:${finalTag}" -ForegroundColor Cyan
        }

        $tags = @(
            "${repositoryName}:${finalTag}",
            "${ContainerRegistryName}/${repositoryName}:${finalTag}",
            "${ContainerRegistryName}/${repositoryName}:${baseTag}"
        )
        if ($UsePrebaked -and $AgentVersion) {
            $agentVersionSlug = ($AgentVersion.ToLowerInvariant() -replace '[^0-9a-z\.-]', '-').Trim('-')
            if (-not $agentVersionSlug) { $agentVersionSlug = 'unknown' }

            $finalAgentTag = "${finalTag}-agent-$agentVersionSlug"
            $finalAgentRepoTag = "${ContainerRegistryName}/${repositoryName}:${finalAgentTag}"
            $baseAgentTag = "${baseTag}-agent-$agentVersionSlug"
            $baseAgentRepoTag = "${ContainerRegistryName}/${repositoryName}:${baseAgentTag}"

            foreach ($agentTag in @("${repositoryName}:${finalAgentTag}", $finalAgentRepoTag, $baseAgentRepoTag)) {
                if ($agentTag -and ($tags -notcontains $agentTag)) {
                    $tags += $agentTag
                }
            }
        }
        if ($SemVer -and $SemVer -match '^[0-9]+\.[0-9]+\.[0-9]+$') {
            $semverRepoTag = "${ContainerRegistryName}/${repositoryName}:$SemVer"
            if ($finalTag -ne $SemVer -and ($tags -notcontains $semverRepoTag)) {
                Write-Host "Adding semantic version tag: $SemVer"
                $tags += $semverRepoTag
            }
        }
        if (-not $DisableLatest) { $tags += "${ContainerRegistryName}/${repositoryName}:latest" }
        $tagParams = @(); foreach ($t in $tags) { $tagParams += @('--tag', $t) }

        Write-Host "Running docker build with tags:`n  $($tags -join "`n  ")"
        
        $dockerBuildArgs = @('build') + $tagParams
        if ($UsePrebaked) { $dockerBuildArgs += @('--build-arg', "AGENT_VERSION=$AgentVersion") }
        $dockerBuildArgs += @('--file', $dockerFileName, '.')

        $buildExit = Invoke-DockerBuildCommand -Arguments $dockerBuildArgs -FriendlyDescription 'build'
        $hypervRetried = $false
        if ($buildExit -ne 0 -and $EnableHypervFallback) {
            if (-not (Test-HyperVIsolationSupport)) {
                Write-Warning "docker build failed with exit code $buildExit and Hyper-V isolation is not available on this host."
                Write-Warning "Either enable Hyper-V with nested virtualization support or restrict WindowsVersions to host-compatible releases (for example 2022/2025)."
                Write-Error "Cannot fall back to --isolation=hyperv on this machine."
                return
            }
            $hypervRetried = $true
            Write-Warning "docker build failed with exit code $buildExit. Retrying with --isolation=hyperv (requires Hyper-V feature and Windows 10/11 Pro/Enterprise or Windows Server)."
            Start-Sleep -Seconds 5
            $hypervArgs = @('build', '--isolation=hyperv') + $tagParams
            if ($UsePrebaked) { $hypervArgs += @('--build-arg', "AGENT_VERSION=$AgentVersion") }
            $hypervArgs += @('--file', $dockerFileName, '.')
            $buildExit = Invoke-DockerBuildCommand -Arguments $hypervArgs -FriendlyDescription 'build --isolation=hyperv'
        }

        if ($buildExit -ne 0) {
            if ($hypervRetried) {
                Write-Error "docker build failed even with --isolation=hyperv (exit code $buildExit)."
            }
            else {
                Write-Error "docker build failed with exit code $buildExit."
            }
            return
        }

        & az account show >$null 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Not logged into Azure CLI. Attempting 'az acr login' directly (will fail if auth not pre-configured)."
        }
        az acr login --name $acrShort | Out-Null

        $pushFailures = @()
        foreach ($t in $tags | Where-Object { $_ -like "$ContainerRegistryName*" }) {
            Write-Host "Pushing $t"
            docker push $t 2>&1 | ForEach-Object { Write-Host $_ }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Push failed for $t (exit code $LASTEXITCODE)"
                $pushFailures += $t
            }
        }
        if ($pushFailures.Count -gt 0) {
            Write-Warning ("Some pushes failed for repository {0}: {1}" -f $repositoryName, ($pushFailures -join ', '))
            # If every tag push failed, treat as error to surface failure; otherwise continue but warn.
            $allTags = ($tags | Where-Object { $_ -like "$ContainerRegistryName*" })
            if ($pushFailures.Count -eq $allTags.Count) {
                Write-Error "All pushes failed for $repositoryName"
            }
            else {
                Write-Host ("Completed push (partial success) {0}:{1}" -f $repositoryName, $finalTag) -ForegroundColor Yellow
            }
        }
        else {
            Write-Green ("Completed push {0}:{1}" -f $repositoryName, $finalTag)
        }
    } # end foreach
} # end function

# Execute the build function with the bound parameters so the script is safe when dot-sourced
Invoke-WindowsBuild @PSBoundParameters