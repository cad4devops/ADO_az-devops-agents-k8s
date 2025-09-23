param(
    [string[]]$WindowsVersions = @("2019","2022","2025"),
    [string]$ContainerRegistryName = $env:ACR_NAME,
    [string]$TagSuffix = $env:TAG_SUFFIX,
    [string]$SemVer = $env:SEMVER_EFFECTIVE,
    [switch]$DisableLatest
)

$ErrorActionPreference = 'Stop'

if (-not $ContainerRegistryName) { $ContainerRegistryName = "cragentssgvhe4aipy37o.azurecr.io" }
$acrShort = $ContainerRegistryName.Split('.')[0]

foreach ($windowsVersion in $WindowsVersions) {
    $baseTag = "windows-${windowsVersion}"
    $finalTag = if ($TagSuffix) { "$baseTag-$TagSuffix" } else { $baseTag }
    $repositoryName = "windows-sh-agent-${windowsVersion}"
    $dockerFileName = "./Dockerfile.${repositoryName}-windows${windowsVersion}"

        Write-Host "Building Windows image ${repositoryName}:${finalTag}" -ForegroundColor Cyan

        $tags = @(
            "${repositoryName}:${finalTag}",
            "${ContainerRegistryName}/${repositoryName}:${finalTag}",
            "${ContainerRegistryName}/${repositoryName}:${baseTag}"
        )
        if($SemVer -and $SemVer -match '^[0-9]+\.[0-9]+\.[0-9]+$'){
            $semverRepoTag = "${ContainerRegistryName}/${repositoryName}:$SemVer"
            if($finalTag -ne $SemVer -and ($tags -notcontains $semverRepoTag)){
                Write-Host "Adding semantic version tag: $SemVer"
                $tags += $semverRepoTag
            }
        }
        if (-not $DisableLatest) { $tags += "${ContainerRegistryName}/${repositoryName}:latest" }
        $tagParams = @(); foreach($t in $tags){ $tagParams += @('--tag', $t) }

        Write-Host "Running docker build with tags:`n  $($tags -join "`n  ")"
        docker build @tagParams --file "$dockerFileName" .

        if (-not (az account show 2>$null)) {
            Write-Warning "Not logged into Azure CLI. Attempting 'az acr login' directly (will fail if auth not pre-configured)."
        }
        az acr login --name $acrShort | Out-Null

        foreach($t in $tags | Where-Object { $_ -like "$ContainerRegistryName*" }){
            Write-Host "Pushing $t"
            docker push $t | Write-Host
        }
        Write-Host "Completed push ${repositoryName}:${finalTag}" -ForegroundColor Green
}