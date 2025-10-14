Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Wrapper to invoke deploy-selfhosted-agents-helm.ps1 using environment variables injected by the pipeline.
# This avoids complex YAML templating and ensures typed booleans are passed reliably via splatting.

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
# repoRoot should be two levels up from the scripts folder (repo/.azuredevops/scripts -> repo root)
$scriptDirItem = Get-Item $scriptRoot -ErrorAction SilentlyContinue
if ($scriptDirItem -and $scriptDirItem.Parent -and $scriptDirItem.Parent.Parent) {
    $repoRoot = $scriptDirItem.Parent.Parent.FullName
} else {
    # fallback: single level up
    $repoRoot = Split-Path -Parent $scriptRoot
}
$scriptPath = Join-Path $repoRoot 'deploy-selfhosted-agents-helm.ps1'
if (-not (Test-Path $scriptPath)) { Write-Error "Deploy helper not found at $scriptPath"; exit 1 }

# Read environment vars (pipeline will set these)
$envKube = $env:KUBECONFIG
$envAzDo = $env:AZDO_PAT
$envPipelineAcr = $env:PIPELINE_ACR_NAME
$envAcrName = if ($envPipelineAcr) { $envPipelineAcr } else { $env:ACR_NAME }
$envAcrUser = $env:ACR_USERNAME
$envAcrPass = $env:ACR_PASSWORD
$envKubeAzureLocal = $env:KUBECONFIG_AZURE_LOCAL
$envKubeContextAzureLocal = $env:KUBECONTEXT_AZURE_LOCAL
# Avoid picking up unexpanded pipeline template tokens which look like '$(VAR)'. Treat them as absent.
if ($envAcrUser -and $envAcrUser -match '^\$\(.+\)$') { Write-Host "Detected unexpanded ACR username token '$envAcrUser' in environment; ignoring."; $envAcrUser = $null }
if ($envAcrPass -and $envAcrPass -match '^\$\(.+\)$') { Write-Host "Detected unexpanded ACR password token in environment; ignoring."; $envAcrPass = $null }
$envInstance = $env:INSTANCE_NUMBER
$envDeployLinux = $env:DEPLOY_LINUX
$envDeployWindows = $env:DEPLOY_WINDOWS
$envAzOrg = $env:AZDO_ORG_URL

# Normalize and fallback defaults
if (-not $envInstance) { $envInstance = '003' }

# Enforce that ACR_NAME is provided by the pipeline parameter. Treat pipeline parameter as the
# single source of truth for which container registry to use. Fail fast if missing to avoid
# silently falling back to an incorrect registry.
if (-not $envAcrName) {
    Write-Error "ACR_NAME is not set in the job environment and no pipeline ACR was provided. The pipeline must pass the ACR via the ACR_NAME parameter. Aborting to avoid deploying values with an incorrect registry."
    exit 1
}

# Log both values (if present) to aid debugging of where the value came from
if ($envPipelineAcr -and $env:ACR_NAME -and ($envPipelineAcr -ne $env:ACR_NAME)) {
    Write-Host "Note: PIPELINE_ACR_NAME='$envPipelineAcr' differs from job env ACR_NAME='$($env:ACR_NAME)'. Using PIPELINE_ACR_NAME as authoritative."
}

# Helper to convert string-ish env values to boolean
function ToBool([string]$s) {
    if (-not $s) { return $false }
    return ($s -match '^(?i:true|1|yes)$')
}

# Build parameter hashtable with correct types
$psParams = @{}
if ($envKube) { $psParams.Kubeconfig = $envKube }
$psParams.InstanceNumber = $envInstance
$psParams.AcrName = $envAcrName
if ($envAcrUser) { $psParams.AcrUsername = $envAcrUser }
if ($envAcrPass) { $psParams.AcrPassword = $envAcrPass }
if ($envAzOrg) { $psParams.AzureDevOpsOrgUrl = $envAzOrg }
if ($envAzDo) { $psParams.AzDevOpsToken = $envAzDo }
# Ensure pool creation unless explicitly disabled
$psParams.EnsureAzDoPools = $true

if (ToBool $envDeployLinux) { $psParams.DeployLinux = $true }
if (ToBool $envDeployWindows) { $psParams.DeployWindows = $true }

# Mask token for logs
$masked = if ($envAzDo) { '***' } else { '(none)' }
Write-Host "Invoking $scriptPath with Instance=$envInstance, AcrName=$envAcrName, AzureDevOpsOrgUrl=$envAzOrg, AzDoToken=$masked, DeployLinux=$(ToBool $envDeployLinux), DeployWindows=$(ToBool $envDeployWindows)"

# Debug: surface the explicit USE_AZURE_LOCAL and KUBECONFIG values so pipeline logs show the mode selected
Write-Host "DEBUG: USE_AZURE_LOCAL env='${env:USE_AZURE_LOCAL}' KUBECONFIG='${env:KUBECONFIG}' KUBECONFIG_AZURE_LOCAL='${env:KUBECONFIG_AZURE_LOCAL}' KUBECONTEXT_AZURE_LOCAL='${env:KUBECONTEXT_AZURE_LOCAL}'"

# Call the deploy script in a new PowerShell process to avoid in-process parsing/context issues
# Build an argument list and pass typed switches/values
$argList = @()
if ($envKube) { $argList += '-Kubeconfig'; $argList += $envKube }
# Only treat the kubeconfig as 'local' when the pipeline explicitly requested local mode.
# The pipeline sets USE_AZURE_LOCAL env var (true/false) and we should honor that instead
# of inferring local mode from the mere presence of KUBECONFIG (which is also set when
# az aks get-credentials runs in non-local mode).
$helmTimeoutOverride = $env:HELM_TIMEOUT
if ($env:USE_AZURE_LOCAL -and (ToBool $env:USE_AZURE_LOCAL)) {
    Write-Host "DEBUG: Wrapper detected USE_AZURE_LOCAL=true; forwarding -UseAzureLocal to child"
    $argList += '-UseAzureLocal'
    # If pipeline provided local kubeconfig and context values, forward them explicitly
    if ($envKubeAzureLocal) { $argList += '-KubeconfigAzureLocal'; $argList += $envKubeAzureLocal }
    if ($envKubeContextAzureLocal) { $argList += '-KubeContextAzureLocal'; $argList += $envKubeContextAzureLocal }
    if (-not $helmTimeoutOverride) {
        $helmTimeoutOverride = '10m'
        Write-Host "DEBUG: Defaulting HelmTimeout to $helmTimeoutOverride for Azure Local runs"
    }
} else {
    Write-Host "DEBUG: Wrapper not forwarding -UseAzureLocal (USE_AZURE_LOCAL='${env:USE_AZURE_LOCAL}')"
}
$argList += '-InstanceNumber'; $argList += $envInstance
$argList += '-AcrName'; $argList += $envAcrName
if ($envAcrUser) { $argList += '-AcrUsername'; $argList += $envAcrUser }
if ($envAcrPass) { $argList += '-AcrPassword'; $argList += $envAcrPass }
if ($envAzOrg) { $argList += '-AzureDevOpsOrgUrl'; $argList += $envAzOrg }
if ($envAzDo) { $argList += '-AzDevOpsToken'; $argList += $envAzDo }
# EnsureAzDoPools should always be true unless explicitly disabled by not setting it in the wrapper
$argList += '-EnsureAzDoPools'
if (ToBool $envDeployLinux) { $argList += '-DeployLinux' }
if (ToBool $envDeployWindows) { $argList += '-DeployWindows' }
if ($helmTimeoutOverride) { $argList += '-HelmTimeout'; $argList += $helmTimeoutOverride }

Write-Host "Launching deploy script in child pwsh with args: $($argList -join ' ')"
& pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File $scriptPath @argList
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) { Write-Error "Deploy script exited with code $exitCode"; exit $exitCode }
