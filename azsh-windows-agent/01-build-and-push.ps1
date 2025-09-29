param(
    [string[]]$WindowsVersions = @("2019","2022","2025"),
    [string]$ContainerRegistryName = $env:ACR_NAME,
    [string]$TagSuffix = $env:TAG_SUFFIX,
    [string]$SemVer = $env:SEMVER_EFFECTIVE,
    [switch]$DisableLatest
)

$ErrorActionPreference = 'Stop'

# Add DefaultAcr parameter and prefer explicit config over hardcoded fallback
param(
    [string]$DefaultAcr = 'cragents003c66i4n7btfksg'
)

# Resolve ContainerRegistryName: prefer provided parameter, then DEFAULT_ACR env var, then DefaultAcr fallback
if (-not $ContainerRegistryName) {
    if ($env:DEFAULT_ACR) {
        $ContainerRegistryName = $env:DEFAULT_ACR
    } elseif ($DefaultAcr) {
        $ContainerRegistryName = $DefaultAcr
    } else {
        $ContainerRegistryName = 'cragents003c66i4n7btfksg'
    }
}

# If user supplied an unqualified registry name (no dot), assume Azure Container Registry and append the azurecr.io suffix
if ($ContainerRegistryName -and ($ContainerRegistryName -notmatch '\.')) {
    Write-Host "ContainerRegistryName '$ContainerRegistryName' appears unqualified; appending '.azurecr.io' to form FQDN"
    $ContainerRegistryName = "$ContainerRegistryName.azurecr.io"
}

$acrShort = $ContainerRegistryName.Split('.')[0]

# If WindowsVersions was provided as a script parameter (e.g. via -WindowsVersions), keep it.
# Otherwise, fall back to environment variables WINDOWS_VERSIONS or WIN_VERSION if present.
if (-not $PSBoundParameters.ContainsKey('WindowsVersions')) {
    if ($env:WINDOWS_VERSIONS) {
        $parsed = $env:WINDOWS_VERSIONS.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if ($parsed.Count -gt 0) {
            $WindowsVersions = $parsed
            Write-Host "Using WINDOWS_VERSIONS from environment: $($WindowsVersions -join ',')"
        }
    } elseif ($env:WIN_VERSION) {
        $WindowsVersions = @($env:WIN_VERSION.Trim())
        Write-Host "Using WIN_VERSION from environment: $($WindowsVersions -join ',')"
    }
}

# Log effective list of windows versions we will build
Write-Host "Effective WindowsVersions: $($WindowsVersions -join ',')"

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

        $pushFailures = @()
        foreach($t in $tags | Where-Object { $_ -like "$ContainerRegistryName*" }){
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
            } else {
                Write-Host ("Completed push (partial success) {0}:{1}" -f $repositoryName,$finalTag) -ForegroundColor Yellow
            }
        } else {
            Write-Host ("Completed push {0}:{1}" -f $repositoryName,$finalTag) -ForegroundColor Green
        }
}