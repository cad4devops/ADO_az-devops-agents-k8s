<#
.SYNOPSIS
    Builds and pushes Linux Azure DevOps agent Docker images to Azure Container Registry.

.DESCRIPTION
    This script builds Docker images for Linux-based Azure DevOps self-hosted agents and pushes
    them to an Azure Container Registry (ACR). It supports two build modes:
    
    1. PRE-BAKED (default): Downloads the Azure Pipelines agent at build time and includes it
       in the image. This results in faster agent startup times but larger images.
    
    2. STANDARD: The agent is downloaded at container runtime. This creates smaller images
       but has slower startup times.
    
    The script automatically:
    - Normalizes unqualified ACR names by appending .azurecr.io
    - Fetches the latest Azure Pipelines agent version if not specified (prebaked mode)
    - Creates multiple image tags including base, versioned, and latest tags
    - Logs into ACR using Azure CLI
    - Pushes all tags to the registry with error handling

.PARAMETER ContainerRegistryName
    The name or FQDN of the Azure Container Registry. If unqualified (no dots), 
    '.azurecr.io' will be appended automatically. Can be set via ACR_NAME environment variable.
    Example: 'cragents003c66i4n7btfksg' or 'cragents003c66i4n7btfksg.azurecr.io'

.PARAMETER RepositoryName
    The Docker repository name within the ACR. Defaults to 'linux-sh-agent-docker'.
    Can be set via LINUX_REPOSITORY_NAME environment variable.

.PARAMETER BaseTag
    The base tag for the image, typically indicating the OS version.
    Defaults to 'ubuntu-24.04'. Can be set via LINUX_BASE_TAG environment variable.

.PARAMETER TagSuffix
    Optional suffix to append to the base tag, typically a date and commit SHA.
    Example: '20250920-a1b2c3d'. Can be set via TAG_SUFFIX environment variable.

.PARAMETER SemVer
    Semantic version to use as an additional tag (e.g., '1.0.0').
    Can be set via SEMVER_EFFECTIVE environment variable.

.PARAMETER DisableLatest
    If specified, the 'latest' tag will not be applied to the image.

.PARAMETER DefaultAcr
    Default ACR name to use when ContainerRegistryName is not provided.
    This is mandatory to ensure the script always has a target registry.

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

.EXAMPLE
    pwsh ./01-build-and-push.ps1 -DefaultAcr 'cragents003c66i4n7btfksg'
    
    Builds and pushes a prebaked Linux agent image using the latest agent version
    to the specified ACR.

.EXAMPLE
    pwsh ./01-build-and-push.ps1 -DefaultAcr 'myregistry' -UseStandard -TagSuffix '20250101-abc123'
    
    Builds and pushes a standard (runtime download) Linux agent image with a specific tag suffix.

.EXAMPLE
    $env:ACR_NAME = 'cragents003.azurecr.io'
    $env:TAG_SUFFIX = '20250920-a1b2c3d'
    $env:SEMVER_EFFECTIVE = '1.2.3'
    pwsh ./01-build-and-push.ps1 -DefaultAcr 'fallback'
    
    Uses environment variables for configuration (common in CI pipelines).

.NOTES
    Prerequisites:
    - Docker must be installed and running
    - Azure CLI (az) must be installed and authenticated
    - Current directory must be azsh-linux-agent/ containing the Dockerfiles
    
    CI Usage:
    This script is designed to be called from Azure DevOps pipelines. Environment variables
    are preferred in CI scenarios to avoid exposing credentials in logs.
    
    File: azsh-linux-agent/01-build-and-push.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ContainerRegistryName = $env:ACR_NAME,
    [Parameter(Mandatory = $false)]
    [string]$RepositoryName = $env:LINUX_REPOSITORY_NAME,
    [Parameter(Mandatory = $false)]
    [string]$BaseTag = $env:LINUX_BASE_TAG,
    [Parameter(Mandatory = $false)]
    [string]$TagSuffix = $env:TAG_SUFFIX,
    [Parameter(Mandatory = $false)]
    [string]$SemVer = $env:SEMVER_EFFECTIVE,
    [Parameter(Mandatory = $false)]
    [switch]$DisableLatest,
    # Default ACR short name (no .azurecr.io). Can be overridden by passing this parameter
    # or by setting the DEFAULT_ACR environment variable in CI.
    [Parameter(Mandatory = $true)]
    [string]$DefaultAcr, #'cragents003c66i4n7btfksg'
    [Parameter(Mandatory = $false)]
    [switch]$UsePrebaked = $true,
    [Parameter(Mandatory = $false)]
    [switch]$UseStandard,
    [Parameter(Mandatory = $false)]
    [string]$AgentVersion
)

$ErrorActionPreference = 'Stop'

# Cross-platform green output helper for CI logs
function Write-Green([string]$msg) {
    try { if ($IsWindows) { Write-Host -ForegroundColor Green $msg } else { Write-Host "`e[32m$msg`e[0m" } } catch { Write-Host $msg }
}

if (-not $ContainerRegistryName) {
    # Prefer an explicit DefaultAcr parameter, then DEFAULT_ACR env var, then built-in fallback
    if ($DefaultAcr) {
        $ContainerRegistryName = $DefaultAcr
    }
    elseif ($env:DEFAULT_ACR) {
        $ContainerRegistryName = $env:DEFAULT_ACR
    }
    else {
        $ContainerRegistryName = $DefaultAcr #'cragents003c66i4n7btfksg'
    }
}
# If user supplied an unqualified registry name (no dot), assume Azure Container Registry and append the azurecr.io suffix
if ($ContainerRegistryName -and ($ContainerRegistryName -notmatch '\.')) {
    Write-Host "ContainerRegistryName '$ContainerRegistryName' appears unqualified; appending '.azurecr.io' to form FQDN"
    $ContainerRegistryName = "$ContainerRegistryName.azurecr.io"
}
if (-not $RepositoryName) { $RepositoryName = "linux-sh-agent-docker" }
if (-not $BaseTag) { $BaseTag = "ubuntu-24.04" }

# Determine build mode: UseStandard overrides default UsePrebaked
if ($UseStandard) {
    $UsePrebaked = $false
    Write-Host "Using STANDARD agent Dockerfile (agent downloaded at runtime)" -ForegroundColor Yellow
}
elseif ($UsePrebaked) {
    Write-Host "Using PRE-BAKED agent Dockerfile (agent downloaded at build time)" -ForegroundColor Magenta
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

# Compose final tag (e.g. ubuntu-24.04-20250920-a1b2c3d)
$FinalTag = if ($TagSuffix) { "$BaseTag-$TagSuffix" } else { $BaseTag }

# Choose Dockerfile based on prebaked flag
$dockerfileRepoName = $RepositoryName
if ($RepositoryName -eq 'linux-sh-agent-dind') {
    $dockerfileRepoName = 'linux-sh-agent-docker'
    Write-Host "DinD repository '$RepositoryName' reuses Dockerfile.$dockerfileRepoName" -ForegroundColor Yellow
}

if ($UsePrebaked) {
    $dockerFileName = "./Dockerfile.${dockerfileRepoName}.prebaked"
    Write-Host "Building PREBAKED Linux image: $RepositoryName with agent v${AgentVersion}" -ForegroundColor Cyan
}
else {
    $dockerFileName = "./Dockerfile.${dockerfileRepoName}"
    Write-Host "Building STANDARD Linux image: $RepositoryName" -ForegroundColor Cyan
}
if (-not (Test-Path $dockerFileName)) {
    throw "Dockerfile '$dockerFileName' not found for repository '$RepositoryName'"
}
Write-Host " Registry : $ContainerRegistryName"
Write-Host " BaseTag  : $BaseTag"
Write-Host " FinalTag : $FinalTag"

# Build tag argument list safely (avoid concatenated flag/value token)
$tags = @(
    "${RepositoryName}:${FinalTag}",
    "${ContainerRegistryName}/${RepositoryName}:${FinalTag}",
    "${ContainerRegistryName}/${RepositoryName}:${BaseTag}"
)

if ($UsePrebaked -and $AgentVersion) {
    $agentVersionSlug = ($AgentVersion.ToLowerInvariant() -replace '[^0-9a-z\.-]', '-').Trim('-')
    if (-not $agentVersionSlug) { $agentVersionSlug = 'unknown' }

    $finalAgentTag = "${FinalTag}-agent-$agentVersionSlug"
    $finalAgentRepoTag = "${ContainerRegistryName}/${RepositoryName}:${finalAgentTag}"
    $baseAgentTag = "${BaseTag}-agent-$agentVersionSlug"
    $baseAgentRepoTag = "${ContainerRegistryName}/${RepositoryName}:${baseAgentTag}"

    foreach ($agentTag in @("${RepositoryName}:${finalAgentTag}", $finalAgentRepoTag, $baseAgentRepoTag)) {
        if ($agentTag -and ($tags -notcontains $agentTag)) {
            $tags += $agentTag
        }
    }
}

# If SemVer looks like Major.Minor.Patch and isn't already identical to FinalTag, add an extra semantic tag
if ($SemVer -and $SemVer -match '^[0-9]+\.[0-9]+\.[0-9]+$') {
    $semverRepoTag = "${ContainerRegistryName}/${RepositoryName}:$SemVer"
    if ($FinalTag -ne $SemVer -and ($tags -notcontains $semverRepoTag)) {
        Write-Host "Adding semantic version tag: $SemVer"
        $tags += $semverRepoTag
    }
}
if (-not $DisableLatest) { $tags += "${ContainerRegistryName}/${RepositoryName}:latest" }

$tagParams = @()
foreach ($t in $tags) { $tagParams += @('--tag', $t) }

Write-Host "Running docker build with tags:`n  $($tags -join "`n  ")"

# Build with agent version as build arg for prebaked images
if ($UsePrebaked) {
    Write-Host "Agent Version: $AgentVersion" -ForegroundColor Cyan
    docker build @tagParams --build-arg AGENT_VERSION=$AgentVersion --file "$dockerFileName" .
}
else {
    docker build @tagParams --file "$dockerFileName" .
}

$acrShort = $ContainerRegistryName.Split('.')[0]
Write-Host "Logging into ACR: $acrShort"
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
    Write-Warning ("Some pushes failed for repository {0}: {1}" -f $RepositoryName, ($pushFailures -join ', '))
    $allTags = ($tags | Where-Object { $_ -like "$ContainerRegistryName*" })
    if ($pushFailures.Count -eq $allTags.Count) {
        Write-Error "All pushes failed for $RepositoryName"
    }
    else {
        Write-Host ("Completed push (partial success) {0}:{1}" -f $RepositoryName, $FinalTag) -ForegroundColor Yellow
    }
}
else {
    Write-Green ("Completed push for {0}:{1}" -f $RepositoryName, $FinalTag)
}