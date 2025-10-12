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
if ($UsePrebaked) {
    $dockerFileName = "./Dockerfile.${RepositoryName}.prebaked"
    Write-Host "Building PREBAKED Linux image: $RepositoryName with agent v${AgentVersion}" -ForegroundColor Cyan
}
else {
    $dockerFileName = "./Dockerfile.${RepositoryName}"
    Write-Host "Building STANDARD Linux image: $RepositoryName" -ForegroundColor Cyan
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