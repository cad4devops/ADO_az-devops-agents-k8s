param(
    [string]$ContainerRegistryName = $env:ACR_NAME,
    [string]$RepositoryName = $env:LINUX_REPOSITORY_NAME,
    [string]$BaseTag = $env:LINUX_BASE_TAG,
    [string]$TagSuffix = $env:TAG_SUFFIX,
    [string]$SemVer = $env:SEMVER_EFFECTIVE,
    [switch]$DisableLatest
)

$ErrorActionPreference = 'Stop'

if (-not $ContainerRegistryName) { $ContainerRegistryName = "cragentssgvhe4aipy37o.azurecr.io" }
if (-not $RepositoryName) { $RepositoryName = "linux-sh-agent-docker" }
if (-not $BaseTag) { $BaseTag = "ubuntu-24.04" }

# Compose final tag (e.g. ubuntu-24.04-20250920-a1b2c3d)
$FinalTag = if ($TagSuffix) { "$BaseTag-$TagSuffix" } else { $BaseTag }

$dockerFileName = "./Dockerfile.${RepositoryName}"

Write-Host "Building image: $RepositoryName" -ForegroundColor Cyan
Write-Host " Registry : $ContainerRegistryName"
Write-Host " BaseTag  : $BaseTag"
Write-Host " FinalTag : $FinalTag"

# Build tag argument list safely (avoid concatenated flag/value token)
$tags = @(
    "${RepositoryName}:${FinalTag}",
    "${ContainerRegistryName}/${RepositoryName}:${FinalTag}",
    "${ContainerRegistryName}/${RepositoryName}:${BaseTag}"
)

# If SemVer looks like Major.Minor.Patch and isn't already identical to FinalTag, add an extra semantic tag
if($SemVer -and $SemVer -match '^[0-9]+\.[0-9]+\.[0-9]+$'){
    $semverRepoTag = "${ContainerRegistryName}/${RepositoryName}:$SemVer"
    if($FinalTag -ne $SemVer -and ($tags -notcontains $semverRepoTag)){
        Write-Host "Adding semantic version tag: $SemVer"
        $tags += $semverRepoTag
    }
}
if (-not $DisableLatest) { $tags += "${ContainerRegistryName}/${RepositoryName}:latest" }

$tagParams = @()
foreach($t in $tags){ $tagParams += @('--tag', $t) }

Write-Host "Running docker build with tags:`n  $($tags -join "`n  ")"
docker build @tagParams --file "$dockerFileName" .

$acrShort = $ContainerRegistryName.Split('.')[0]
Write-Host "Logging into ACR: $acrShort"
az acr login --name $acrShort | Out-Null

foreach($t in $tags | Where-Object { $_ -like "$ContainerRegistryName*" }){
    Write-Host "Pushing $t"
    docker push $t | Write-Host
}

Write-Host ("Completed push for {0}:{1}" -f $RepositoryName,$FinalTag) -ForegroundColor Green