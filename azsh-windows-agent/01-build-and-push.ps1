param(
    [Parameter(Mandatory = $false)]
    [string[]]$WindowsVersions = @("2019", "2022", "2025"),
    [Parameter(Mandatory = $false)]
    [string]$ContainerRegistryName = $env:ACR_NAME,
    [Parameter(Mandatory = $false)]
    [string]$TagSuffix = $env:TAG_SUFFIX,
    [Parameter(Mandatory = $false)]
    [string]$SemVer = $env:SEMVER_EFFECTIVE,
    [Parameter(Mandatory = $false)]
    [switch]$DisableLatest,
    [Parameter(Mandatory = $false)]
    [string]$DefaultAcr
)

function Invoke-WindowsBuild {
    param(
        [Parameter(Mandatory = $false)]
        [string[]]$WindowsVersions = @("2019", "2022", "2025"),
        [Parameter(Mandatory = $false)]
        [string]$ContainerRegistryName = $env:ACR_NAME,
        [Parameter(Mandatory = $false)]
        [string]$TagSuffix = $env:TAG_SUFFIX,
        [Parameter(Mandatory = $false)]
        [string]$SemVer = $env:SEMVER_EFFECTIVE,
        [Parameter(Mandatory = $false)]
        [switch]$DisableLatest,
        [Parameter(Mandatory = $true)]
        [string]$DefaultAcr #'cragents003c66i4n7btfksg'
    )

    $ErrorActionPreference = 'Stop'
    # Reuse cross-platform green writer for CI-friendly logs
    function Write-Green([string]$msg) {
        try { if ($IsWindows) { Write-Host -ForegroundColor Green $msg } else { Write-Host "`e[32m$msg`e[0m" } } catch { Write-Host $msg }
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
    $canonicalDefault = '2019,2022,2025'

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
        docker build @tagParams --file "$dockerFileName" .

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