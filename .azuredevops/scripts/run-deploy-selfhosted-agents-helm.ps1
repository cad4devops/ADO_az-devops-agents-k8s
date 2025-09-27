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
$envAcrName = $env:ACR_NAME
$envAcrUser = $env:ACR_USERNAME
$envAcrPass = $env:ACR_PASSWORD
$envInstance = $env:INSTANCE_NUMBER
$envDeployLinux = $env:DEPLOY_LINUX
$envDeployWindows = $env:DEPLOY_WINDOWS
$envAzOrg = $env:AZDO_ORG_URL

# Normalize and fallback defaults
if (-not $envInstance) { $envInstance = '003' }
if (-not $envAcrName) { $envAcrName = 'cragentssgvhe4aipy37o' }

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
if ($envAzOrg) { $psParams.AzureDevOpsOrgUrl = $envAzOrg; $AzDevOpsUrl = $envAzOrg }
if ($envAzDo) { $psParams.AzDevOpsToken = $envAzDo }
# Ensure pool creation unless explicitly disabled
$psParams.EnsureAzDoPools = $true

if (ToBool $envDeployLinux) { $psParams.DeployLinux = $true }
if (ToBool $envDeployWindows) { $psParams.DeployWindows = $true }

# Mask token for logs
$masked = if ($envAzDo) { '***' } else { '(none)' }
Write-Host "Invoking $scriptPath with Instance=$envInstance, AcrName=$envAcrName, AzureDevOpsOrgUrl=$envAzOrg, AzDoToken=$masked, DeployLinux=$(ToBool $envDeployLinux), DeployWindows=$(ToBool $envDeployWindows)"

# Call the deploy script in a new PowerShell process to avoid in-process parsing/context issues
# Build an argument list and pass typed switches/values
$argList = @()
if ($envKube) { $argList += '-Kubeconfig'; $argList += $envKube }
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

Write-Host "Launching deploy script in child pwsh with args: $($argList -join ' ')"
& pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File $scriptPath @argList
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) { Write-Error "Deploy script exited with code $exitCode"; exit $exitCode }
