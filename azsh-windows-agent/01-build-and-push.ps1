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
    [switch]$UsePrebaked,
    [Parameter(Mandatory = $false)]
    [switch]$UseStandard,
    [Parameter(Mandatory = $false)]
    [string]$AgentVersion,
    [Parameter(Mandatory = $false)]
    [switch]$EnableHypervFallback,
    [Parameter(Mandatory = $false)]
    [switch]$UseDinD
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
    [switch]$UsePrebaked,
        [Parameter(Mandatory = $false)]
        [switch]$UseStandard,
        [Parameter(Mandatory = $false)]
        [string]$AgentVersion,
        [Parameter(Mandatory = $false)]
    [switch]$EnableHypervFallback,
        [Parameter(Mandatory = $false)]
        [switch]$UseDinD
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
    if (-not $PSBoundParameters.ContainsKey('UsePrebaked')) { $UsePrebaked = $true }
    if (-not $PSBoundParameters.ContainsKey('EnableHypervFallback')) { $EnableHypervFallback = $true }

    if ($UseDinD) {
        # DinD images are pre-baked by design so we keep UsePrebaked flag true and disable the standard path
        $UsePrebaked = $true
        $UseStandard = $false
        Write-Host "Using WINDOWS DinD Dockerfiles (host-process capable image)" -ForegroundColor Cyan
    }
    elseif ($UseStandard) {
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
        if ($UseDinD) {
            $repositoryName = "windows-sh-agent-${windowsVersion}-dind"
            $baseTag = "windows-${windowsVersion}-dind"
        }
        else {
            $repositoryName = "windows-sh-agent-${windowsVersion}"
            $baseTag = "windows-${windowsVersion}"
        }
        $finalTag = if ($TagSuffix) { "$baseTag-$TagSuffix" } else { $baseTag }
        
        # Choose Dockerfile based on prebaked flag
        if ($UseDinD) {
            $dockerFileName = "./Dockerfile.${repositoryName}-windows${windowsVersion}-dind"
            if (-not (Test-Path $dockerFileName)) {
                $fallbackDockerfile = "./Dockerfile.windows-sh-agent-${windowsVersion}-windows${windowsVersion}-dind"
                if (Test-Path $fallbackDockerfile) {
                    Write-Verbose "Falling back to Dockerfile naming variant: $fallbackDockerfile"
                    $dockerFileName = $fallbackDockerfile
                }
            }
            Write-Host "Building WINDOWS DinD image ${repositoryName}:${finalTag} with agent v${AgentVersion}" -ForegroundColor Cyan
        }
        elseif ($UsePrebaked) {
            $dockerFileName = "./Dockerfile.${repositoryName}-windows${windowsVersion}.prebaked"
            Write-Host "Building PREBAKED Windows image ${repositoryName}:${finalTag} with agent v${AgentVersion}" -ForegroundColor Cyan
        }
        else {
            $dockerFileName = "./Dockerfile.${repositoryName}-windows${windowsVersion}"
            Write-Host "Building STANDARD Windows image ${repositoryName}:${finalTag}" -ForegroundColor Cyan
        }

        if (-not (Test-Path $dockerFileName)) {
            Write-Error "Dockerfile not found at $dockerFileName"
            return
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
$scriptParamTable = @{}
foreach ($pair in $PSBoundParameters.GetEnumerator()) {
    $scriptParamTable[$pair.Key] = $pair.Value
}
if (-not $scriptParamTable.ContainsKey('UsePrebaked')) { $scriptParamTable['UsePrebaked'] = $true }
if (-not $scriptParamTable.ContainsKey('EnableHypervFallback')) { $scriptParamTable['EnableHypervFallback'] = $true }

Invoke-WindowsBuild @scriptParamTable