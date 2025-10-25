<#
.azuredevops/scripts/bootstrap-and-build.ps1

Orchestrator script to:
 1) Deploy infra (calls infra/bicep/deploy.ps1)
 2) Extract useful outputs (instance number, ACR name, AKS name, AKS RG)
 3) Build & push linux and windows images (calls azsh-*/01-build-and-push.ps1)
 4) Render pipeline templates from .template.yml files by replacing tokens

This script is intended to be run from a CI job or locally where Azure CLI,
Docker (for builds), and pwsh are available.

Usage examples:
  pwsh .\.azuredevops\scripts\bootstrap-and-build.ps1 -InstanceNumber 003 -Location canadacentral

Notes:
- The deploy step will attempt to create or update resources in the specified resource group.
- The build steps will attempt to login to the created ACR and push images; ensure Docker and build hosts are available.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstanceNumber,
    [Parameter(Mandatory = $true)][string]$Location,
    [Parameter(Mandatory = $true)][string]$ADOCollectionName,
    [Parameter(Mandatory = $true)][string]$AzureDevOpsProject,
    [Parameter(Mandatory = $true)][string]$AzureDevOpsRepo,
    [Parameter(Mandatory = $false)][string]$AzureDevOpsProjectWikiName = "$AzureDevOpsProject.wiki",
    [Parameter(Mandatory = $false)][string]$ResourceGroupName,
    [Parameter(Mandatory = $false)][string]$ContainerRegistryName, # = "devopsabcsrunners", # specify your container registry name or leave empty to create one
    [Parameter(Mandatory = $false)][switch]$BuildInPipeline,
    [Parameter(Mandatory = $false)][switch]$EnableWindows,
    [Parameter(Mandatory = $false)][int]$WindowsNodeCount = 1,
    [Parameter(Mandatory = $false)][int]$LinuxNodeCount = 1,
    [Parameter(Mandatory = $false)][string]$LinuxVmSize = 'Standard_D4s_v3',
    [Parameter(Mandatory = $false)][string]$WindowsVmSize = 'Standard_D2s_v3',
    [Parameter(Mandatory = $false)][string]$AzureDevOpsOrgUrl = "https://dev.azure.com/$ADOCollectionName",


    [Parameter(Mandatory = $false)][string]$BootstrapPoolName = 'KubernetesPoolWindows',
    [Parameter(Mandatory = $false)][string]$KubeconfigAzureLocalPath = "workload-cluster-$InstanceNumber-kubeconfig.yaml",
    [Parameter(Mandatory = $false)][string]$KubeContextAzureLocal = "workload-cluster-$InstanceNumber-admin@workload-cluster-$InstanceNumber",
    [Parameter(Mandatory = $false)][string]$KubeConfigFilePath = "${HOME}\.kube\workload-cluster-$InstanceNumber-kubeconfig.yaml",
    # Default service connection name now derived from repo + instance for predictability
    [Parameter(Mandatory = $false)][string]$AzureDevOpsServiceConnectionName = "$AzureDevOpsRepo-wif-sc-$InstanceNumber", # Azure RM service connection name (WIF)
    [Parameter(Mandatory = $false)][string]$AzureDevOpsVariableGroup = "$AzureDevOpsRepo-$InstanceNumber",
    [Parameter(Mandatory = $false)][string]$AzureDevOpsPatTokenEnvironmentVariableName = "AZDO_PAT",
    [Parameter(Mandatory = $false)][string]$InstallPipelineName = "$AzureDevOpsRepo-deploy-self-hosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$UninstallPipelineName = "$AzureDevOpsRepo-uninstall-selfhosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$ValidatePipelineName = "$AzureDevOpsRepo-validate-self-hosted-agents-helm",
    [Parameter(Mandatory = $false)][string]$ImageRefreshPipelineName = "$AzureDevOpsRepo-weekly-image-refresh",
    [Parameter(Mandatory = $false)][string]$RunOnPoolSamplePipelineName = "$AzureDevOpsRepo-run-on-selfhosted-pool-sample-helm",
    [Parameter(Mandatory = $false)][string]$DeployAksInfraPipelineName = "$AzureDevOpsRepo-deploy-aks-helm",
    [Parameter(Mandatory = $false)][string]$DeployAksHciInfraPipelineName = "$AzureDevOpsRepo-deploy-aks-hci-helm",
    [Parameter(Mandatory = $false)][string]$KubeConfigSecretFile = "AKS_workload-cluster-$InstanceNumber-kubeconfig_file",
    [Parameter(Mandatory = $false)][string]$UbuntuOnPremPoolName = "UbuntuLatestPoolOnPrem",
    [Parameter(Mandatory = $false)][string]$WindowsOnPremPoolName = "WindowsLatestPoolOnPrem",
    [Parameter(Mandatory = $false)][string]$UseOnPremAgents = "false",
    [Parameter(Mandatory = $false)][switch]$UseAzureLocal,
    [Parameter(Mandatory = $false)][switch]$EnsureWindowsDocker,

    # Optional: create (idempotently) an Azure Resource Manager service connection using Workload Identity Federation
    [Parameter(Mandatory = $false)][switch]$CreateWifServiceConnection,
    [Parameter(Mandatory = $false)][string]$SubscriptionId,
    [Parameter(Mandatory = $false)][string]$SubscriptionName,
    [Parameter(Mandatory = $false)][string]$TenantId,
    [Parameter(Mandatory = $false)][string]$ServicePrincipalClientId, # Entra ID application (client) id configured with federated credential for ADO
    [Parameter(Mandatory = $false)][switch]$AssignSpContributorRole # If set, will attempt to assign Contributor role to the SP at the subscription scope
    ,
    # Optional: also create (or ensure) the Entra application/service principal and federated credential used for WIF
    [Parameter(Mandatory = $false)][switch]$CreateServicePrincipal,
    [Parameter(Mandatory = $false)][string]$ServicePrincipalDisplayName = "ado-agents-wif-$InstanceNumber",
    # Federated identity mapping fields (Issuer/Subject/Audience) are public identifiers, NOT secrets.
    # Renamed to drop the word 'Credential' to avoid security analyzer false positives.
    # Suppress PSAvoidUsingPlainTextForPassword (if triggered): these are not passwords/secrets.
    [Parameter(Mandatory = $false)][ValidateNotNullOrEmpty()][string]$FederatedIssuer,   # e.g. https://vstoken.dev.azure.com/{organization}
    [Parameter(Mandatory = $false)][ValidateNotNullOrEmpty()][string]$FederatedSubject,  # e.g. sc://AzureAD/{projectId}/{serviceConnectionId}
    [Parameter(Mandatory = $false)][ValidateNotNullOrEmpty()][string]$FederatedAudience = 'api://AzureADTokenExchange'
    ,
    # Use the newer Azure AD issuer form instead of the legacy Azure DevOps OIDC issuer when set.
    # New style (as now shown in some ADO portal guidance): https://login.microsoftonline.com/{tenantId}/v2.0
    # NOTE: When using -UseAadIssuer the subject format presented in the portal typically resembles:
    #   /eid1/c/pub/t/<tenantToken>/a/<audienceToken>/sc/<projectId>/<serviceConnectionId>
    # These middle dynamic segments (t/<...>/a/<...>) are environment/tenant specific and cannot be reliably
    # derived locally. Therefore the script will REQUIRE that you pass -FederatedSubject explicitly whenever
    # -UseAadIssuer is specified (unless future discovery logic is added).
    [Parameter(Mandatory = $false)][switch]$UseAadIssuer
    ,
    # Control auto-behavior: disable automatic creation when ServicePrincipalClientId not provided
    [Parameter(Mandatory = $false)][switch]$DisableAutoServicePrincipal
    ,
    # Debug: emit detailed WIF service connection creation payload & response
    [Parameter(Mandatory = $false)][switch]$DebugWifCreation,
    # Federated credential creation tuning & diagnostics
    [Parameter(Mandatory = $false)][int]$FederatedCredentialMaxRetries = 5,
    [Parameter(Mandatory = $false)][int]$FederatedCredentialRetrySecondsBase = 4,
    [Parameter(Mandatory = $false)][switch]$DebugFederatedCredential
    ,
    # If a duplicate WIF service connection exists but the PAT lacks permission to list/view it, proceed (build images) instead of failing fast.
    # Federated credential creation will be skipped unless -FederatedSubject is explicitly provided.
    [Parameter(Mandatory = $false)][switch]$ProceedOnDuplicateNoVisibility
    ,
    # When duplicate exists but not visible to PAT, optionally supply known existing service connection id to compute FederatedSubject.
    [Parameter(Mandatory = $false)][string]$ExistingServiceConnectionId
    ,
    # Attempt automatic detection & repair of azure-devops CLI extension permission issues (Access is denied) by removing & reinstalling the extension.
    [Parameter(Mandatory = $false)][switch]$AutoRepairAzDevOpsExtension
)

$scriptRoot = Split-Path -Parent $PSCommandPath
$sharedInstallerPath = Join-Path $scriptRoot 'scripts/Install-DockerOnWindowsNodes.ps1'
if (-not (Test-Path -LiteralPath $sharedInstallerPath)) {
    throw "Shared installer module not found at $sharedInstallerPath"
}
. $sharedInstallerPath

# Ensure the shared installer exported the expected function before continuing.
if (-not (Get-Command -Name Install-DockerOnWindowsNodes -CommandType Function -ErrorAction SilentlyContinue)) {
    throw 'Install-DockerOnWindowsNodes not defined after importing shared installer module.'
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Normalize $IsWindows for both PowerShell Core and Windows PowerShell.
# Strict mode requires that we explicitly set it when the automatic variable is unavailable (e.g. Windows PowerShell 5.x).
$resolvedIsWindows = $null
foreach ($scope in 'Script', 'Global') {
    try {
        $var = Get-Variable -Name IsWindows -Scope $scope -ErrorAction Stop
        if ($null -ne $var) {
            $value = $var.Value
            if ($value -is [bool]) {
                $resolvedIsWindows = $value
            }
            elseif ($null -ne $value) {
                try { $resolvedIsWindows = [System.Convert]::ToBoolean($value) } catch { $resolvedIsWindows = $null }
            }
            if ($null -ne $resolvedIsWindows) { break }
        }
    }
    catch { }
}
if ($null -eq $resolvedIsWindows) {
    try {
        $resolvedIsWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
    }
    catch {
        try {
            $resolvedIsWindows = [bool]([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
        }
        catch { $resolvedIsWindows = $false }
    }
}
Set-Variable -Name IsWindows -Scope Script -Value ([bool]$resolvedIsWindows) -Force


# Load .env file if it exists (before validation)
$envFile = Join-Path $PSScriptRoot '.env'
if (Test-Path $envFile) {
    Write-Host "Loading environment variables from .env file..."
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        # Skip empty lines and comments
        if ($line -and -not $line.StartsWith('#')) {
            if ($line -match '^([^=]+)=(.*)$') {
                $name = $matches[1].Trim()
                $value = $matches[2].Trim()
                # Remove surrounding quotes if present
                if ($value -match '^["''](.*)["'']$') {
                    $value = $matches[1]
                }
                Set-Item -Path "env:$name" -Value $value
                Write-Host "  Loaded: $name"
            }
        }
    }
}

# Helper functions (must be defined before use)
function Fail([string]$msg) { Write-Error $msg; exit 1 }

function Write-Green([string]$msg) { try { if ($IsWindows) { Write-Host -ForegroundColor Green $msg } else { Write-Host "`e[32m$msg`e[0m" } } catch { Write-Host $msg } }

# Helper to mask PAT for safe logging (preserve first 4 + last 4 chars)
function MaskPat([string]$pat) {
    if (-not $pat) { return '(empty)' }
    if ($pat.Length -le 8) { return '****' }
    $mid = -join (1..($pat.Length - 8) | ForEach-Object { '*' })
    return $pat.Substring(0, 4) + $mid + $pat.Substring($pat.Length - 4)
}

# Validate required environment variable
if ([string]::IsNullOrWhiteSpace($env:AZDO_PAT)) {
    Write-Error @"
ERROR: Required environment variable 'AZDO_PAT' is not set.

The Azure DevOps Personal Access Token (PAT) is required to create/update:
  - Variable groups
  - Pipelines
  - Secure files

Please set the AZDO_PAT environment variable before running this script:

  `$env:AZDO_PAT = 'your-actual-pat-token'

Or create a .env file in the repository root with:
  AZDO_PAT=your-actual-pat-token

See docs/bootstrap-env.md for PAT scope requirements.
"@
    exit 1
}

# Validate PAT is not the default placeholder value
if ($env:AZDO_PAT -eq 'your-pat-token-here' -or $env:AZDO_PAT -match '^your-pat-token' -or $env:AZDO_PAT -eq 'your-actual-pat-token') {
    Write-Error @"
ERROR: AZDO_PAT contains a placeholder value ('$($env:AZDO_PAT)').

Please set a valid Azure DevOps Personal Access Token.
The PAT must have the following scopes:
  - Agent Pools (Read & manage)
  - Build (Read & execute)
  - Code (Read)
  - Variable Groups (Read, create & manage)

See docs/bootstrap-env.md for detailed PAT creation instructions.
"@
    exit 1
}

# Output masked PAT for debugging (safe to log)
Write-Host "AZDO_PAT validation passed (masked): $(MaskPat $env:AZDO_PAT)"

# Switch Docker Desktop engine between linux and windows on Windows hosts when available
function Switch-DockerEngine([ValidateSet('linux', 'windows')][string]$target, [int]$timeoutSeconds = 60, [int]$postSwitchDelaySeconds = 0) {
    if (-not $IsWindows) { Write-Host "Not on Windows host; skipping Docker engine switch to '$target'"; return }
    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if (-not $dockerCmd) { Write-Warning "docker CLI not found; cannot check engine. Skipping switch."; return }

    # Path to Docker Desktop CLI helper
    $possible = @(((Join-Path $Env:ProgramFiles 'Docker\Docker\DockerCli.exe'), (Join-Path $Env:ProgramFiles 'Docker\DockerCli.exe')) | Where-Object { Test-Path $_ })

    if ($possible.Count -gt 0) {
        $dockerCli = $possible[0]
        if ($target -eq 'linux') { $arg = '-SwitchLinuxEngine' } else { $arg = '-SwitchWindowsEngine' }
        Write-Host "Attempting to switch Docker Desktop engine to '$target' using $dockerCli $arg"
        try {
            & "$dockerCli" $arg 2>$null | Out-Null
        }
        catch { Write-Warning "Failed to invoke DockerCli.exe: $($_.Exception.Message)" }
        # Poll docker info for OSType
        $deadline = (Get-Date).AddSeconds($timeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            try {
                $ostype = (& docker info --format '{{.OSType}}' 2>$null).Trim()
                if ($ostype -eq $target) {
                    Write-Host "Docker engine now reports OSType='$ostype'"
                    if ($postSwitchDelaySeconds -gt 0) {
                        Write-Host "Waiting $postSwitchDelaySeconds seconds for Docker engine to stabilize..."
                        Start-Sleep -Seconds $postSwitchDelaySeconds
                    }
                    return
                }
            }
            catch {
                # ignore transient errors while Docker restarts
            }
        }
        Write-Warning "Timed out waiting for Docker engine to report OSType='$target'"
    }
    else {
        Write-Warning "Docker Desktop CLI (DockerCli.exe) not found under Program Files; attempting to set DOCKER_DEFAULT_PLATFORM for the upcoming build as a fallback."
        if ($postSwitchDelaySeconds -gt 0) {
            Write-Host "Waiting $postSwitchDelaySeconds seconds before continuing build steps..."
            Start-Sleep -Seconds $postSwitchDelaySeconds
        }
    }
}

# Resolve script and repo roots
$scriptPath = $MyInvocation.MyCommand.Path
$scriptRoot = Split-Path -Parent $scriptPath
$repoRoot = Resolve-Path (Join-Path $scriptRoot '.')

Write-Host "Script root: $scriptRoot"
Write-Host "Repo root  : $repoRoot"

$AzureDevOpsVariableGroupBase = $AzureDevOpsVariableGroup

if ($UseAzureLocal.IsPresent) {
    $azureLocalSuffix = '-azurelocal'

    if (-not $AzureDevOpsVariableGroup.EndsWith($azureLocalSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "UseAzureLocal set; AzureDevOpsVariableGroup suffixed with '$azureLocalSuffix'."
        $AzureDevOpsVariableGroup = "$AzureDevOpsVariableGroup$azureLocalSuffix"
    }

    if (-not $KubeConfigSecretFile.EndsWith($azureLocalSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "UseAzureLocal set; KubeConfigSecretFile suffixed with '$azureLocalSuffix'."
        $KubeConfigSecretFile = "$KubeConfigSecretFile$azureLocalSuffix"
    }
}

# Validate parameter combinations early
if ($UseAzureLocal.IsPresent -and [string]::IsNullOrWhiteSpace($ContainerRegistryName)) {
    Fail "-UseAzureLocal requires that you also provide -ContainerRegistryName because the Azure Local helper does not create an ACR."
}

# Default ResourceGroupName if not provided
if (-not $ResourceGroupName -or [string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = "rg-aks-ado-agents-$InstanceNumber"
    Write-Host "No ResourceGroupName provided. Defaulting to: $ResourceGroupName"
}

# Decide how to provision infrastructure
$deployOutputs = $null
$rawOut = @()

if ($UseAzureLocal.IsPresent) {
    Write-Host "UseAzureLocal switch detected. Skipping Azure Bicep deploy and invoking AKS-HCI helper script."
    if (-not $IsWindows) { Fail "-UseAzureLocal requires running on Windows so Windows PowerShell 5.x is available." }

    $desktopPwsh = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $desktopPwsh)) {
        Fail "Windows PowerShell (powershell.exe) not found at expected path '$desktopPwsh'. Install Windows PowerShell 5.x or adjust the script to locate it."
    }

    $manageScript = Join-Path $repoRoot 'infra\scripts\AzureLocal\Manage-AksHci-WorkloadCluster.ps1'
    if (-not (Test-Path $manageScript)) { Fail "Azure Local helper script not found at $manageScript" }

    Write-Host "Invoking Manage-AksHci-WorkloadCluster.ps1 via Windows PowerShell." 

    $kubeConfigDirectory = $null
    try { $kubeConfigDirectory = Split-Path -Parent $KubeConfigFilePath } catch { $kubeConfigDirectory = $null }
    if ($kubeConfigDirectory -and -not (Test-Path $kubeConfigDirectory)) {
        Write-Host "Creating directory for kubeconfig: $kubeConfigDirectory"
        New-Item -ItemType Directory -Path $kubeConfigDirectory -Force | Out-Null
    }

    $winCountInt = 0
    try { $winCountInt = [int]$WindowsNodeCount } catch { $winCountInt = 0 }
    $wantsWindowsNodes = $EnableWindows.IsPresent -or ($winCountInt -gt 0)
    if (-not $EnableWindows.IsPresent -and $winCountInt -gt 0) {
        Write-Host "WindowsNodeCount=$winCountInt provided without -EnableWindows; enabling Windows node provisioning."
    }

    $effectiveWindowsNodeCount = if ($wantsWindowsNodes) { [string]$winCountInt } else { '0' }

    $manageArgs = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $manageScript,
        '-InstanceNumber', $InstanceNumber,
        '-LinuxNodeCount', [string]$LinuxNodeCount,
        '-WindowsNodeCount', $effectiveWindowsNodeCount,
        '-KubeConfigPath', $KubeConfigFilePath,
        '-WaitForProvisioning',
        '-ProvisioningTimeoutMinutes', '40',
        '-CollectDiagnosticsOnFailure',
        '-AutoApprove'
    )
    if ($LinuxVmSize) { $manageArgs += '-LinuxNodeVmSize'; $manageArgs += $LinuxVmSize }
    if ($WindowsVmSize) { $manageArgs += '-WindowsNodeVmSize'; $manageArgs += $WindowsVmSize }

    Write-Host "powershell.exe arguments: $($manageArgs -join ' ')"

    $rawOut = & $desktopPwsh @manageArgs 2>&1
    $manageExit = $LASTEXITCODE
    if ($manageExit -ne 0) {
        $joinedManage = $rawOut -join "`n"
        if ($joinedManage) { Write-Warning $joinedManage }
        Fail "Manage-AksHci-WorkloadCluster.ps1 exited with code $manageExit"
    }
    Write-Host "Manage-AksHci-WorkloadCluster.ps1 completed successfully."
}
else {
    # Deploy infra by invoking the bicep deploy helper
    $deployScript = Join-Path $repoRoot 'infra\bicep\deploy.ps1'
    if (-not (Test-Path $deployScript)) { Fail "Deploy script not found at $deployScript" }

    Write-Host "Invoking infra deploy: $deployScript"

    $deployArgs = @(
        '-InstanceNumber', $InstanceNumber,
        '-Location', $Location,
        '-ResourceGroupName', $ResourceGroupName,
        '-WindowsNodeCount', [string]$WindowsNodeCount,
        '-LinuxNodeCount', [string]$LinuxNodeCount,
        '-LinuxVmSize', $LinuxVmSize,
        '-WindowsVmSize', $WindowsVmSize
    )
    if ($EnableWindows.IsPresent) { $deployArgs += '-EnableWindows'; $deployArgs += $true }
    if ($ContainerRegistryName) { $deployArgs += '-ContainerRegistryName'; $deployArgs += $ContainerRegistryName }
    if ($ContainerRegistryName) { $deployArgs += '-SkipContainerRegistry'; }

    # Capture output (stdout + stderr) for parsing
    Write-Host "Running deploy.ps1 with: $($deployArgs -join ' ')"
    $rawOut = & pwsh -NoProfile -NonInteractive -File $deployScript @deployArgs 2>&1
    if ($LASTEXITCODE -ne 0) { Write-Warning "deploy.ps1 exited with code $LASTEXITCODE; output may contain partial information." }

    # Attempt to extract the JSON that the deploy script prints after 'Deployment outputs:'
    $joined = $rawOut -join "`n"
    try {
        $m = [regex]::Match($joined, 'Deployment outputs:\s*(\{.*\})', [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if ($m.Success) {
            $jsonText = $m.Groups[1].Value
            $deployOutputs = $jsonText | ConvertFrom-Json -ErrorAction Stop
            Write-Host "Parsed deployment outputs from deploy.ps1"
        }
        else {
            Write-Host "No explicit 'Deployment outputs:' JSON block found in deploy.ps1 output. Falling back to discovery."
        }
    }
    catch {
        Write-Warning "Failed to parse deployment outputs JSON: $($_.Exception.Message)"; $deployOutputs = $null
    }
}

# Determine ACR name
$acrName = $null
if ($ContainerRegistryName -and -not [string]::IsNullOrWhiteSpace($ContainerRegistryName)) {
    $acrName = $ContainerRegistryName
    Write-Host "Using ContainerRegistryName parameter: $acrName"
}
elseif ($deployOutputs -and $deployOutputs.containerRegistryName -and $deployOutputs.containerRegistryName.value) {
    $acrName = $deployOutputs.containerRegistryName.value
    Write-Host "Found containerRegistryName in deploy outputs: $acrName"
}

if (-not $acrName) {
    if ($UseAzureLocal.IsPresent) {
        Fail "When -UseAzureLocal is specified you must provide -ContainerRegistryName so the script knows which registry to use."
    }

    Write-Host "Attempting to discover ACRs in resource group $ResourceGroupName"
    $acrListJson = az acr list -g $ResourceGroupName --query "[].name" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $acrListJson) {
        $acrCandidates = @($acrListJson -split "\n" | Where-Object { $_ -ne '' })
        if ($acrCandidates.Count -eq 1) { $acrName = $acrCandidates[0]; Write-Host "Discovered single ACR in RG: $acrName" }
        elseif ($acrCandidates.Count -gt 1) { $acrName = $acrCandidates[0]; Write-Warning "Multiple ACRs found in RG; picking first: $acrName" }
    }
}

if (-not $acrName) { Fail "Unable to determine container registry name. Provide -ContainerRegistryName or ensure the Azure deploy produces an output 'containerRegistryName'." }

# Normalize ACR values
if ($acrName -match '\.') { $acrFqdn = $acrName; $acrShort = $acrName.Split('.')[0] } else { $acrShort = $acrName; $acrFqdn = "$acrShort.azurecr.io" }
Write-Host "ACR short: $acrShort  ACR FQDN: $acrFqdn"

# AKS name and resource group
if ($UseAzureLocal.IsPresent) {
    $aksName = "workload-cluster-$InstanceNumber"
    Write-Host "Using AKS-HCI workload cluster name: $aksName"
}
else {
    $aksName = "aks-ado-agents-$InstanceNumber"
    Write-Host "Assumed AKS name: $aksName"
}

# Fail-fast: If requested, ensure a Workload Identity Federation based Azure RM service connection exists BEFORE expensive image builds.
if ($CreateWifServiceConnection) {
    Write-Host "CreateWifServiceConnection switch set: attempting early ensure of Workload Identity Federation ARM service connection '$AzureDevOpsServiceConnectionName'."

    # Fallback to environment variables when explicit parameters not supplied
    if (-not $SubscriptionId -and $env:AZ_SUBSCRIPTION_ID) { $SubscriptionId = $env:AZ_SUBSCRIPTION_ID }
    if (-not $SubscriptionName -and $env:AZ_SUBSCRIPTION_NAME) { $SubscriptionName = $env:AZ_SUBSCRIPTION_NAME }
    if (-not $TenantId -and $env:AZ_TENANT_ID) { $TenantId = $env:AZ_TENANT_ID }
    if (-not $ServicePrincipalClientId -and $env:AZ_SP_APP_ID) { $ServicePrincipalClientId = $env:AZ_SP_APP_ID }

    # Attempt auto-discovery from current az login context if still missing
    if (-not $SubscriptionId -or -not $TenantId) {
        try {
            $acct = az account show -o json 2>$null
            if ($LASTEXITCODE -eq 0 -and $acct) {
                $acctObj = $acct | ConvertFrom-Json
                if (-not $SubscriptionId) { $SubscriptionId = $acctObj.id }
                if (-not $SubscriptionName) { $SubscriptionName = $acctObj.name }
                if (-not $TenantId) { $TenantId = $acctObj.tenantId }
                Write-Host "Auto-discovered subscription/tenant from az account show: $SubscriptionName ($SubscriptionId) tenant=$TenantId"
            }
        }
        catch { Write-Host "Auto-discovery via az account show failed: $($_.Exception.Message)" }
    }
    if (-not $FederatedIssuer -and $env:AZ_WIF_ISSUER) { $FederatedIssuer = $env:AZ_WIF_ISSUER }
    if (-not $FederatedSubject -and $env:AZ_WIF_SUBJECT) { $FederatedSubject = $env:AZ_WIF_SUBJECT }
    # Apply computed defaults if still empty
    if (-not $FederatedIssuer) {
        if ($UseAadIssuer) {
            if (-not $TenantId) { Fail "-UseAadIssuer specified but TenantId is missing. Provide -TenantId or set AZ_TENANT_ID." }
            $FederatedIssuer = "https://login.microsoftonline.com/$TenantId/v2.0"
            Write-Host "Using Azure AD issuer (new style): $FederatedIssuer"
        }
        else {
            $FederatedIssuer = "https://vstoken.dev.azure.com/$ADOCollectionName"
            Write-Host "Using legacy Azure DevOps OIDC issuer: $FederatedIssuer"
        }
    }
    # If user opted into new issuer style but did not provide a subject, fail fast with guidance.
    if ($UseAadIssuer -and -not $FederatedSubject) {
        $msg = @()
        $msg += ""
        $msg += "-UseAadIssuer was specified but no -FederatedSubject provided."
        $msg += "The new issuer style requires a portal-displayed subject path similar to:"
        $msg += "/eid1/c/pub/t/<tenantToken>/a/<audToken>/sc/<projectId>/<serviceConnectionId>"
        $msg += "These dynamic middle segments cannot currently be auto-derived by this script."
        $msg += "Action: Re-run providing the exact subject shown in the Azure DevOps service connection UI using -FederatedSubject."
        Fail ($msg -join [Environment]::NewLine)
    }
    # We can't know service connection id yet; we'll defer subject computation if not supplied.
    $deferFederatedSubject = $false
    if (-not $FederatedSubject) { $deferFederatedSubject = $true }

    # If no ServicePrincipalClientId but auto creation allowed, toggle CreateServicePrincipal implicitly
    if (-not $ServicePrincipalClientId -and -not $DisableAutoServicePrincipal) {
        if (-not $CreateServicePrincipal) { Write-Host "No ServicePrincipalClientId supplied; auto-enabling -CreateServicePrincipal to generate one." }
        $CreateServicePrincipal = $true
    }

    $missing = @()
    if (-not $SubscriptionId) { $missing += 'SubscriptionId (env AZ_SUBSCRIPTION_ID or az account show)' }
    if (-not $TenantId) { $missing += 'TenantId (env AZ_TENANT_ID or az account show)' }
    if ($missing.Count -gt 0) { Fail ("Cannot create Workload Identity Federation service connection; missing: { 0 }" -f ($missing -join ', ')) }

    $wifCreationSucceeded = $false

    # Optionally create or ensure the Entra application / service principal and federated credential
    if ($CreateServicePrincipal) {
        Write-Host "CreateServicePrincipal set: ensuring Entra application & service principal exist (early)."
        try {
            $script:AppObjectId = $null
            $script:SpObjectId = $null
            if (-not $ServicePrincipalClientId) {
                # Try to locate existing app by display name
                $existingAppJson = az ad app list --display-name $ServicePrincipalDisplayName --query "[0]" -o json 2>$null
                if ($LASTEXITCODE -eq 0 -and $existingAppJson) {
                    try {
                        $appInfo = $existingAppJson | ConvertFrom-Json
                        if ($appInfo.appId) {
                            $ServicePrincipalClientId = $appInfo.appId.Trim()
                            $script:AppObjectId = $appInfo.id
                            Write-Host "Found existing application displayName=$ServicePrincipalDisplayName (appId=$ServicePrincipalClientId appObjId=$($script:AppObjectId))."
                        }
                    }
                    catch { }
                }
            }
            if (-not $ServicePrincipalClientId) {
                Write-Host "Creating new Entra application displayName=$ServicePrincipalDisplayName"
                $appCreate = az ad app create --display-name $ServicePrincipalDisplayName -o json 2>$null
                if ($LASTEXITCODE -ne 0 -or -not $appCreate) { Write-Warning "Failed to create Entra application." } else {
                    try { $appObj = $appCreate | ConvertFrom-Json; $ServicePrincipalClientId = $appObj.appId; $script:AppObjectId = $appObj.id } catch {}
                    Write-Host "Created appId=$ServicePrincipalClientId appObjId=$($script:AppObjectId)"
                }
            }
            # Ensure service principal
            if ($ServicePrincipalClientId) {
                $spObjId = az ad sp list --filter "appId eq '$ServicePrincipalClientId'" --query "[0].id" -o tsv 2>$null
                if (-not $spObjId) {
                    Write-Host "Creating service principal for appId $ServicePrincipalClientId"
                    az ad sp create --id $ServicePrincipalClientId 1>$null 2>$null
                    if ($LASTEXITCODE -eq 0) { Write-Host "Service principal created." } else { Write-Warning "Service principal creation may have failed (exit $LASTEXITCODE)." }
                    $spObjId = az ad sp list --filter "appId eq '$ServicePrincipalClientId'" --query "[0].id" -o tsv 2>$null
                }
                else { Write-Host "Service principal already exists (objectId=$spObjId)." }
                $script:SpObjectId = $spObjId
            }
        }
        catch { Write-Warning ("Service principal/app ensure failed: { 0 }" -f $_.Exception.Message) }
    }

    # Ensure azure-devops extension present
    try { az extension show --name azure-devops 1>$null 2>$null } catch { Write-Warning "azure-devops az extension not available; cannot create service connection." }
    $existingScJson = az devops service-endpoint list --org $AzureDevOpsOrgUrl --project $AzureDevOpsProject -o json 2>$null
    $existing = $null
    if ($LASTEXITCODE -eq 0 -and $existingScJson) {
        try { $existing = ($existingScJson | ConvertFrom-Json) | Where-Object { $_.name -eq $AzureDevOpsServiceConnectionName } } catch { $existing = $null }
    }
    if ($existing) {
        $scheme = $existing.authorization.scheme
        if ($scheme -eq 'WorkloadIdentityFederation') {
            Write-Host "Service connection '$AzureDevOpsServiceConnectionName' already exists with WorkloadIdentityFederation scheme. Skipping creation."
            $wifCreationSucceeded = $true
        }
        else {
            Fail "Service connection '$AzureDevOpsServiceConnectionName' already exists with scheme '$scheme'. Manual update required if you intend to use WorkloadIdentityFederation."
        }
        if ($deferFederatedSubject -and $ServicePrincipalClientId) {
            $projectId = az devops project show --org $AzureDevOpsOrgUrl --project $AzureDevOpsProject --query id -o tsv 2>$null
            if ($projectId -and $existing.id) {
                $FederatedSubject = "sc://AzureAD/$projectId/$($existing.id)"
                Write-Host "Computed federated credential subject: $FederatedSubject"
            }
        }
    }
    else {
        # Discover subscription name if not provided
        if (-not $SubscriptionName) {
            $SubscriptionName = (az account subscription show --id $SubscriptionId --query displayName -o tsv 2>$null)
            if (-not $SubscriptionName) { $SubscriptionName = $SubscriptionId }
        }
        # Obtain project id (resilient). First attempt direct show; if empty, configure defaults then retry; final fallback raw REST.
        $projectId = az devops project show --org $AzureDevOpsOrgUrl --project $AzureDevOpsProject --query id -o tsv 2>$null
        if (-not $projectId) {
            Write-Warning "az devops project show returned empty id; attempting to set devops defaults and retry.";
            try { az devops configure --defaults organization=$AzureDevOpsOrgUrl project=$AzureDevOpsProject 1>$null 2>$null } catch { Write-Warning "Failed to configure az devops defaults: $($_.Exception.Message)" }
            $projectId = az devops project show --query id -o tsv 2>$null
        }
        if (-not $projectId) {
            Write-Warning "Retry with REST API for project id..."
            try {
                $orgNoProto = ($AzureDevOpsOrgUrl -replace '^https?://', '')
                $projUrl = "https://$orgNoProto/_apis/projects?api-version=7.0"
                $authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes((':{0}' -f $env:AZDO_PAT)))
                $resp = Invoke-RestMethod -Method Get -Uri $projUrl -Headers @{ Authorization = $authHeader } -ErrorAction Stop
                if ($resp.value) {
                    $matchProj = $resp.value | Where-Object { $_.name -eq $AzureDevOpsProject }
                    if ($matchProj) { $projectId = $matchProj.id; Write-Warning "Resolved project id via REST fallback: $projectId" }
                }
            }
            catch { Write-Warning "REST fallback failed: $($_.Exception.Message)" }
        }
        if (-not $projectId) { Fail "Unable to resolve project id after CLI and REST fallbacks; cannot create service connection." }
        Write-Host "Creating new Workload Identity Federation ARM service connection '$AzureDevOpsServiceConnectionName' in project '$AzureDevOpsProject' (id=$projectId)."
        if (-not $script:SpObjectId -and $ServicePrincipalClientId) { $script:SpObjectId = az ad sp list --filter "appId eq '$ServicePrincipalClientId'" --query "[0].id" -o tsv 2>$null }
        if (-not $script:AppObjectId -and $ServicePrincipalClientId) { $script:AppObjectId = az ad app list --filter "appId eq '$ServicePrincipalClientId'" --query "[0].id" -o tsv 2>$null }
        # Construct minimal + required parameter set; some backends require empty serviceprincipalkey and audience
        # NOTE: Added owner/isShared fields to align with typical Azure DevOps service endpoint payloads and avoid silent validation issues.
        #       Keep payload minimal but explicit; future diagnostics rely on capturing raw body from API even on 400.
        
        # Local helper (scoped) to POST raw JSON while preserving response body on non-success (Invoke-RestMethod disposes content on exception)
        if (-not (Get-Command -Name Invoke-DevOpsJson -ErrorAction SilentlyContinue)) {
            function Invoke-DevOpsJson {
                param(
                    [Parameter(Mandatory)][string]$Url,
                    [Parameter(Mandatory)][string]$Body,
                    [Parameter(Mandatory)][string]$AuthHeader
                )
                try {
                    $handler = [System.Net.Http.HttpClientHandler]::new()
                    $client = [System.Net.Http.HttpClient]::new($handler)
                    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $Url)
                    $req.Headers.Add('Authorization', $AuthHeader)
                    $req.Headers.Add('Accept', 'application/json; api-version=7.1-preview.4')
                    $req.Content = [System.Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8, 'application/json')
                    $resp = $client.SendAsync($req).GetAwaiter().GetResult()
                    $raw = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                    $json = $null
                    if ($raw -and ($raw.TrimStart().StartsWith('{') -or $raw.TrimStart().StartsWith('['))) {
                        try { $json = $raw | ConvertFrom-Json -ErrorAction Stop } catch { }
                    }
                    [pscustomobject]@{
                        StatusCode = [int]$resp.StatusCode
                        Reason     = $resp.ReasonPhrase
                        Headers    = $resp.Headers
                        Body       = $raw
                        Json       = $json
                    }
                }
                catch {
                    return [pscustomobject]@{ StatusCode = -1; Reason = $_.Exception.Message; Body = ''; Json = $null }
                }
            }
        }

        $bodyHashtable = @{
            name                             = $AzureDevOpsServiceConnectionName
            type                             = 'azurerm'
            url                              = 'https://management.azure.com/'
            authorization                    = @{ scheme = 'WorkloadIdentityFederation'; parameters = @{
                    tenantid           = $TenantId
                    serviceprincipalid = $ServicePrincipalClientId
                } 
            }
            data                             = @{
                subscriptionId   = $SubscriptionId
                subscriptionName = $SubscriptionName
                environment      = 'AzureCloud'
                scopeLevel       = 'Subscription'
                # 'scope' field was rejected by API (unexpected); omitting.
                creationMode     = 'Manual'
            }
            owner                            = 'library'
            isShared                         = $false
            serviceEndpointProjectReferences = @(@{ projectReference = @{ id = $projectId }; name = $AzureDevOpsServiceConnectionName; description = 'Created by bootstrap-and-build.ps1 (Workload Identity Federation)' })
        }
        $body = $bodyHashtable | ConvertTo-Json -Depth 12 -Compress
        if ($DebugWifCreation) { Write-Host "WIF Service Connection request body JSON:"; Write-Host $body }
        $authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes((':{0}' -f $env:AZDO_PAT)))
        $orgNoProto = ($AzureDevOpsOrgUrl -replace '^https?://', '')
        $createUrlPrimary = "https://$orgNoProto/_apis/serviceendpoint/endpoints?api-version=7.1-preview.4"
        $createUrlFallback = "https://$orgNoProto/_apis/serviceendpoint/endpoints?api-version=7.0-preview.4" # In case newer preview rejects payload
        $reducedPayloadUsed = $false
        foreach ($attempt in 1..2) {
            $targetUrl = if ($attempt -eq 1) { $createUrlPrimary } else { $createUrlFallback }
            if ($DebugWifCreation) { Write-Host "Attempt $attempt POST $targetUrl (HttpClient helper)" }
            $rawResp = Invoke-DevOpsJson -Url $targetUrl -Body $body -AuthHeader $authHeader
            if ($rawResp.StatusCode -ge 200 -and $rawResp.StatusCode -lt 300) {
                if ($rawResp.Json -and $rawResp.Json.id) {
                    Write-Host "Created service connection id=$($rawResp.Json.id) (attempt $attempt)."
                    $wifCreationSucceeded = $true
                    if ($deferFederatedSubject -and $ServicePrincipalClientId) {
                        $FederatedSubject = "sc://AzureAD/$projectId/$($rawResp.Json.id)"
                        Write-Host "Computed federated credential subject post-create: $FederatedSubject"
                    }
                    break
                }
                else {
                    Write-Warning "Success status but unexpected body (attempt $attempt): $($rawResp.Body)"
                }
            }
            else {
                Write-Warning ("Attempt $attempt failed: HTTP { 0 } { 1 }" -f $rawResp.StatusCode, $rawResp.Reason)
                if ($rawResp.Body) { Write-Warning "Response body (attempt $attempt): $($rawResp.Body)" }
                if ($rawResp.Json) {
                    $msg = $rawResp.Json.message
                    $etype = $rawResp.Json.typeName
                    $ecode = $rawResp.Json.errorCode
                    if ($msg -or $etype -or $ecode) { Write-Warning ("Parsed error details: message='{0}' type='{1}' code='{2}'" -f $msg, $etype, $ecode) }
                    # Graceful handling: duplicate service connection (409) when user lacks visibility but it already exists
                    if ($rawResp.StatusCode -eq 409 -and $msg -match 'already exists' -and -not $wifCreationSucceeded) {
                        Write-Warning 'Duplicate service connection detected. Attempting to locate existing endpoint by name to proceed.'
                        try {
                            $existingListJson = az devops service-endpoint list --org $AzureDevOpsOrgUrl --project $AzureDevOpsProject -o json 2>$null
                            if ($LASTEXITCODE -eq 0 -and $existingListJson) {
                                $existingList = $existingListJson | ConvertFrom-Json
                                $match = $existingList | Where-Object { $_.name -eq $AzureDevOpsServiceConnectionName }
                                if ($match -and $match.id -and $match.authorization.scheme -eq 'WorkloadIdentityFederation') {
                                    Write-Host "Found existing WIF service connection id=$($match.id) via list API; treating as success."
                                    $wifCreationSucceeded = $true
                                    if ($deferFederatedSubject -and $ServicePrincipalClientId) {
                                        $FederatedSubject = "sc://AzureAD/$projectId/$($match.id)"
                                        Write-Host "Computed federated credential subject from existing SC: $FederatedSubject"
                                    }
                                    break
                                }
                                elseif ($match -and $match.id) {
                                    Write-Warning "Existing service connection found with different scheme '$($match.authorization.scheme)'. Manual update required."
                                }
                                else {
                                    Write-Warning 'List API did not return a matching service connection entry; visibility/permission issue likely.'
                                }
                            }
                            else {
                                Write-Warning 'Failed to list service-endpoint resources for duplicate resolution (insufficient permission?).'
                                if ($ProceedOnDuplicateNoVisibility) {
                                    Write-Warning 'ProceedOnDuplicateNoVisibility set: proceeding assuming existing WIF SC is valid.'
                                    $wifCreationSucceeded = $true
                                    if ($ExistingServiceConnectionId) {
                                        Write-Host "ExistingServiceConnectionId provided: $ExistingServiceConnectionId"
                                        if ($deferFederatedSubject -and $ServicePrincipalClientId -and -not $FederatedSubject) {
                                            if (-not $projectId) {
                                                # Attempt to get project id again silently
                                                $projectId = az devops project show --org $AzureDevOpsOrgUrl --project $AzureDevOpsProject --query id -o tsv 2>$null
                                            }
                                            if ($projectId) {
                                                $FederatedSubject = "sc://AzureAD/$projectId/$ExistingServiceConnectionId"
                                                Write-Host "Computed federated credential subject from provided ExistingServiceConnectionId: $FederatedSubject"
                                            }
                                            else {
                                                Write-Warning 'Could not resolve projectId to compute FederatedSubject with ExistingServiceConnectionId.'
                                            }
                                        }
                                    }
                                    else {
                                        Write-Warning 'No ExistingServiceConnectionId supplied; federated credential ensure will be skipped unless FederatedSubject provided.'
                                        if ($deferFederatedSubject) { $FederatedSubject = $null }
                                    }
                                    break
                                }
                            }
                        }
                        catch { Write-Warning "Exception during duplicate resolution: $($_.Exception.Message)" }
                    }
                    # Self-heal: if API lists unexpected fields, remove them & retry once per attempt with reduced payload
                    if (-not $reducedPayloadUsed -and $msg -match 'Following fields in the service connection are not expected:') {
                        $unexpectedLine = ($msg -split '\n')[0]
                        $unexpectedCsv = ($unexpectedLine -split ':', 2)[1]
                        if ($unexpectedCsv) {
                            $unexpected = @($unexpectedCsv -split ',' | ForEach-Object { $_.Trim().Trim('.') } | Where-Object { $_ })
                            $removed = @()
                            $essential = @('name', 'type', 'url', 'subscriptionId', 'subscriptionName', 'environment', 'scopeLevel', 'tenantid', 'serviceprincipalid')
                            foreach ($f in $unexpected) {
                                if ($essential -contains $f) { continue }
                                $removedThis = $false
                                if ($bodyHashtable.authorization.parameters.ContainsKey($f)) { $bodyHashtable.authorization.parameters.Remove($f) | Out-Null; $removed += $f; $removedThis = $true }
                                if (-not $removedThis -and $bodyHashtable.data.ContainsKey($f)) { $bodyHashtable.data.Remove($f) | Out-Null; $removed += $f; $removedThis = $true }
                                if (-not $removedThis -and $bodyHashtable.ContainsKey($f)) { $bodyHashtable.Remove($f) | Out-Null; $removed += $f; $removedThis = $true }
                            }
                            if ($removed.Count -gt 0) {
                                $body = $bodyHashtable | ConvertTo-Json -Depth 12 -Compress
                                Write-Warning "Removed unexpected fields from authorization.parameters: $($removed -join ', '). Retrying same API version with reduced payload..."
                                if ($DebugWifCreation) { Write-Host "Reduced payload JSON:"; Write-Host $body }
                                $reducedPayloadUsed = $true
                                $rawResp = Invoke-DevOpsJson -Url $targetUrl -Body $body -AuthHeader $authHeader
                                if ($rawResp.StatusCode -ge 200 -and $rawResp.StatusCode -lt 300 -and $rawResp.Json -and $rawResp.Json.id) {
                                    Write-Host "Created service connection id=$($rawResp.Json.id) (attempt $attempt after payload reduction)."
                                    $wifCreationSucceeded = $true
                                    if ($deferFederatedSubject -and $ServicePrincipalClientId) {
                                        $FederatedSubject = "sc://AzureAD/$projectId/$($rawResp.Json.id)"
                                        Write-Host "Computed federated credential subject post-create: $FederatedSubject"
                                    }
                                    break
                                }
                                else {
                                    Write-Warning ("Reduced payload retry still failing (HTTP { 0 })." -f $rawResp.StatusCode)
                                    if ($rawResp.Body) { Write-Warning "Reduced retry body: $($rawResp.Body)" }
                                }
                            }
                        }
                    }
                    if ($msg -match 'Manage service connections') { Write-Warning 'Hint: Ensure PAT identity has Project permission: Service connections > Manage service connections.' }
                    if ($msg -match 'approval') { Write-Warning 'Hint: Check Project Settings > Service connections for a pending approval.' }
                    if ($msg -match 'scope' -and $msg -match 'subscription') { Write-Warning 'Hint: Verify SubscriptionId access & correct tenant.' }
                    if ($msg -match 'serviceprincipalid') { Write-Warning 'Hint: SP propagation delay suspected. Add retry with delay.' }
                    if ($msg -match 'owner' -and $msg -match 'isShared') { Write-Warning 'Hint: Owner/isShared validation triggered; verify payload fields.' }
                    if ($msg -match 'WorkloadIdentityFederation' -and $msg -match 'unsupported') { Write-Warning 'Hint: Organization may not have WIF feature enabled. Verify Azure DevOps org preview features.' }
                }
                else {
                    Write-Warning 'No JSON parsed from error body; validation details unknown.'
                }
                if ($attempt -eq 1) { Write-Host 'Retrying with fallback API version...'; Start-Sleep -Seconds 2 }
            }
        }
        if (-not $wifCreationSucceeded) { Fail "Service connection creation failed after retries. Aborting before image builds. Ensure you have 'Manage service connections' permission or an admin approval is not pending." }
    }

    if ($AssignSpContributorRole -and $SubscriptionId) {
        Write-Host "AssignSpContributorRole set: ensuring Contributor role assignment for app $ServicePrincipalClientId on subscription $SubscriptionId"
        try {
            az role assignment create --assignee $ServicePrincipalClientId --role Contributor --scope "/subscriptions/$SubscriptionId" 1>$null 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Host "Contributor role assignment created or already exists." } else { Write-Warning "Role assignment create exited with code $LASTEXITCODE" }
        }
        catch { Write-Warning ("Role assignment attempt failed: { 0 }" -f $_.Exception.Message) }
    }

    # If we deferred the federated credential subject, compute using existing SC id (already handled on create path); then ensure federated credential.
    if ($ProceedOnDuplicateNoVisibility -and -not $FederatedSubject -and $CreateWifServiceConnection) {
        Write-Warning 'Skipping federated credential ensure because we proceeded past a duplicate WIF service connection without visibility and cannot compute FederatedSubject. Provide -FederatedSubject explicitly or rerun with sufficient permissions to list service connections.'
    }
    elseif ($ServicePrincipalClientId -and $FederatedIssuer -and $FederatedSubject) {
        # Normalize accidental escaping/backslashes: result should look like /eid1/c/pub/.../sc/<projectId>/<serviceConnectionId>
        try {
            $origSubject = $FederatedSubject
            # Trim wrapping quotes (both single and double)
            if ($FederatedSubject -match '^".*"$') { $FederatedSubject = $FederatedSubject.Substring(1, $FederatedSubject.Length - 2) }
            elseif ($FederatedSubject -match "^'.*'$") { $FederatedSubject = $FederatedSubject.Substring(1, $FederatedSubject.Length - 2) }
            # Normalize any Windows style backslashes inside to forward slashes (defensive)
            $FederatedSubject = $FederatedSubject -replace '\\', '/'
            # Remove any leading escaped sequences like \/ or multiple leading slashes
            $FederatedSubject = $FederatedSubject -replace '^/+', '/' -replace '^\\+/', '/'
            if (-not $FederatedSubject.StartsWith('/')) { $FederatedSubject = '/' + $FederatedSubject }
            # Remove a single trailing backslash if present (after conversion it would be '/'), then any extra trailing slashes
            $FederatedSubject = $FederatedSubject -replace '/+$', ''
            # Collapse duplicate internal slashes
            while ($FederatedSubject -match '//') { $FederatedSubject = ($FederatedSubject -replace '//', '/') }
            if ($origSubject -ne $FederatedSubject) { Write-Host "Normalized FederatedSubject from '$origSubject' to '$FederatedSubject'" }
            # Sanity check pattern (lightweight): should contain /sc/<guid>/<guid>
            if ($FederatedSubject -notmatch '/sc/[0-9a-fA-F-]{36}/[0-9a-fA-F-]{36}$') { Write-Warning "FederatedSubject '$FederatedSubject' does not match expected trailing /sc/<projectId>/<serviceConnectionId> pattern; verify the value." }
        }
        catch { Write-Warning "Failed to normalize FederatedSubject: $($_.Exception.Message)" }
        Write-Host "Ensuring federated credential (issuer=$FederatedIssuer subject=$FederatedSubject audience=$FederatedAudience) exists for app $ServicePrincipalClientId"
        try {
            $appObjId = $script:AppObjectId
            if (-not $appObjId) {
                $appObjId = az ad app list --filter "appId eq '$ServicePrincipalClientId'" --query "[0].id" -o tsv 2>$null
            }
            if ($appObjId) {
                $fcList = az ad app federated-credential list --id $appObjId -o json 2>&1
                $existsFc = $false
                if ($LASTEXITCODE -eq 0 -and $fcList -and -not [string]::IsNullOrWhiteSpace($fcList)) {
                    try { $fcObjs = $fcList | ConvertFrom-Json; foreach ($fc in $fcObjs) { if ($fc.issuer -eq $FederatedIssuer -and $fc.subject -eq $FederatedSubject) { $existsFc = $true; break } } } catch { }
                }
                elseif ($DebugFederatedCredential) { Write-Warning "List federated-credential returned exit $LASTEXITCODE output: $fcList" }
                if ($existsFc) { Write-Host "Federated credential already present; skipping creation." }
                else {
                    $fcNameBase = "ado-wif-$InstanceNumber"
                    $fcName = $fcNameBase
                    $attempt = 0
                    $created = $false
                    # Removed unused propagationHints variable
                    while (-not $created -and $attempt -lt $FederatedCredentialMaxRetries) {
                        $attempt++
                        if ($attempt -gt 1) { Write-Host "Retry attempt $attempt creating federated credential..." }
                        # Add suffix if name collision suspected
                        if ($attempt -gt 1) { $fcName = "$fcNameBase-$attempt" }
                        if ($DebugFederatedCredential) { Write-Host "Executing: az ad app federated-credential create --id $appObjId --audiences $FederatedAudience --issuer $FederatedIssuer --subject $FederatedSubject --name $fcName" }
                        $createOut = az ad app federated-credential create --id $appObjId --audiences $FederatedAudience --issuer $FederatedIssuer --subject $FederatedSubject --name $fcName -o json 2>&1
                        $exitCode = $LASTEXITCODE
                        if ($exitCode -eq 0) {
                            $created = $true
                            Write-Host "Federated credential created (name=$fcName attempt=$attempt)."
                            if ($DebugFederatedCredential -and $createOut) { Write-Host "Create output: $createOut" }
                            break
                        }
                        else {
                            $outStr = ($createOut | Out-String).Trim()
                            Write-Warning "Federated credential create failed (attempt $attempt exit=$exitCode). Raw output:"; Write-Warning $outStr
                            try {
                                if ($outStr -match '^\s*[{\[]') {
                                    $parsedErr = $outStr | ConvertFrom-Json -ErrorAction Stop
                                    if ($parsedErr.error.message) { Write-Warning "Parsed error message: $($parsedErr.error.message)" }
                                }
                            }
                            catch { }
                            # Detect new az CLI requirement for --parameters file-based input and attempt fallback once per attempt before normal retry logic.
                            if ($outStr -match '--parameters' -or $outStr -match 'required: --parameters' -or $outStr -match 'are required: --parameters' -or ($exitCode -eq 2 -and $outStr -match 'usage:')) {
                                Write-Warning 'az CLI indicates --parameters is required; constructing temporary JSON file for fallback.'
                                try {
                                    $fcJsonObj = [ordered]@{
                                        name        = $fcName
                                        issuer      = $FederatedIssuer
                                        subject     = $FederatedSubject
                                        description = 'Created by bootstrap-and-build.ps1'
                                        audiences   = @($FederatedAudience)
                                    }
                                    $fcJson = $fcJsonObj | ConvertTo-Json -Depth 8 -Compress
                                    $tempFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "fc-$($InstanceNumber)-$($attempt)-$(Get-Random).json")
                                    Set-Content -Path $tempFile -Value $fcJson -Encoding UTF8
                                    if ($DebugFederatedCredential) { Write-Host "Fallback parameters file: $tempFile"; Write-Host $fcJson }
                                    $createOutParams = az ad app federated-credential create --id $appObjId --parameters $tempFile -o json 2>&1
                                    $exitCodeParams = $LASTEXITCODE
                                    if ($exitCodeParams -eq 0) {
                                        $created = $true
                                        Write-Host "Federated credential created using --parameters (name=$fcName attempt=$attempt)."
                                        if ($DebugFederatedCredential -and $createOutParams) { Write-Host "Create output: $createOutParams" }
                                        try { Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue } catch {}
                                        break
                                    }
                                    else {
                                        Write-Warning "Fallback --parameters creation failed (exit $exitCodeParams). Output:"; Write-Warning $createOutParams
                                        try { Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue } catch {}
                                    }
                                }
                                catch {
                                    Write-Warning "Exception during fallback --parameters creation: $($_.Exception.Message)"
                                }
                            }
                            $shouldRetry = $false
                            $retryDelay = [int]([Math]::Pow(2, $attempt - 1) * $FederatedCredentialRetrySecondsBase)
                            if ($outStr -match 'does not exist' -or $outStr -match 'not found' -or $outStr -match 'principal was not found' -or $outStr -match 'Unable to find') { $shouldRetry = $true }
                            if ($outStr -match 'propagation' -or $outStr -match 'cache') { $shouldRetry = $true }
                            if ($outStr -match 'Too Many Requests' -or $outStr -match 'throttl') { $shouldRetry = $true; $retryDelay += 5 }
                            if ($outStr -match 'Insufficient privileges' -or $outStr -match 'Authorization_RequestDenied' -or $outStr -match 'Forbidden') {
                                Write-Warning 'Detected permission issue creating federated credential. Ensure the signed-in identity has Application.ReadWrite.All or is Owner of the app registration (or has Cloud Application Administrator / Application Administrator role).'
                                $shouldRetry = $false
                            }
                            if ($shouldRetry -and $attempt -lt $FederatedCredentialMaxRetries) {
                                Write-Warning "Retrying in ${retryDelay}s (attempt $attempt of $FederatedCredentialMaxRetries)."; Start-Sleep -Seconds $retryDelay
                            }
                            else {
                                if (-not $shouldRetry) { Write-Warning 'Failure does not look transient; aborting retries.' }
                            }
                        }
                    }
                    if (-not $created) {
                        Write-Warning "Federated credential NOT created after $FederatedCredentialMaxRetries attempts. Manual remediation required (see docs/WIF-AUTOMATION-CHANGES.md)."
                        Write-Warning "Manual CLI example (inline flags, may require --parameters JSON on newer CLI):"
                        Write-Warning "az ad app federated-credential create --id $appObjId --audiences $FederatedAudience --issuer $FederatedIssuer --subject $FederatedSubject --name $fcNameBase"
                    }
                }
            }
            else { Write-Warning "Could not resolve application object id for appId=$ServicePrincipalClientId; skipping federated credential ensure." }
        }
        catch {
            $errMsg = $_.Exception.Message
            if ($errMsg -is [System.Array]) { $errMsg = ($errMsg | Out-String).Trim() }
            Write-Warning ("Federated credential ensure failed: { 0 }" -f $errMsg)
        }
    }
    Write-Host "WIF service connection ensure phase complete."
}

# Export variables for downstream pipeline usage (if running in Azure Pipelines)
Write-Host "##vso[task.setvariable variable=INSTANCE_NUMBER]$InstanceNumber"
Write-Host "##vso[task.setvariable variable=ACR_NAME]$acrShort"
Write-Host "##vso[task.setvariable variable=ACR_FQDN]$acrFqdn"
Write-Host "##vso[task.setvariable variable=AKS_NAME]$aksName"
Write-Host "##vso[task.setvariable variable=AKS_RESOURCE_GROUP]$ResourceGroupName"

# Build & push images: Linux
if ($BuildInPipeline) {
    Write-Host "BuildInPipeline is set; skipping local image builds. Images will be built via the weekly image refresh pipeline."
}
else {
    Write-Host "Starting Linux image build/push using azsh-linux-agent/01-build-and-push.ps1"
    $linuxDir = Join-Path $repoRoot 'azsh-linux-agent'
    $linuxScriptName = '01-build-and-push.ps1'
    $linuxScriptPath = Join-Path $linuxDir $linuxScriptName
    if (-not (Test-Path $linuxScriptPath)) {
        Write-Warning "Linux build script not found at $linuxScriptPath; skipping Linux build."
    }
    else {
        # Attempt to ensure Docker is using Linux containers on Windows hosts
        Switch-DockerEngine -target 'linux' -timeoutSeconds 90
        # Run the linux build script from its directory so relative Dockerfile paths resolve correctly
        $cmd = "Set-StrictMode -Version Latest; Set-Location -LiteralPath '$linuxDir'; `$env:DEFAULT_ACR='$acrShort'; `$env:ACR_NAME='$acrShort'; `$env:DOCKER_DEFAULT_PLATFORM='linux'; & .\\$linuxScriptName -ContainerRegistryName '$acrFqdn' -DefaultAcr '$acrShort'"
        Write-Host "Invoking linux build: pwsh -NoProfile -NonInteractive -Command <script in $linuxDir>"
        pwsh -NoProfile -NonInteractive -Command $cmd
        if ($LASTEXITCODE -ne 0) { Write-Warning "Linux build script exited with code $LASTEXITCODE" }
    }
    Write-Host "Starting Windows image builds using azsh-windows-agent/01-build-and-push.ps1"
    $winDir = Join-Path $repoRoot 'azsh-windows-agent'
    $winScriptName = '01-build-and-push.ps1'
    $winScriptPath = Join-Path $winDir $winScriptName
    if (-not (Test-Path $winScriptPath)) {
        Write-Warning "Windows build script not found at $winScriptPath; skipping Windows builds."
    }
    else {
        # Switch Docker to Windows containers when building Windows images
        Switch-DockerEngine -target 'windows' -timeoutSeconds 90 -postSwitchDelaySeconds 15
        # Run the Windows build script in a separate pwsh process and pass parameters explicitly so PSBoundParameters in that script is populated correctly
        $cmd = "Set-StrictMode -Version Latest; Set-Location -LiteralPath '$winDir'; `$env:DEFAULT_ACR='$acrShort'; `$env:ACR_NAME='$acrShort'; & .\$winScriptName -ContainerRegistryName '$acrFqdn' -DefaultAcr '$acrShort'"
        Write-Host "Invoking windows build script in $winDir with explicit parameters"
        pwsh -NoProfile -NonInteractive -Command $cmd
        if ($LASTEXITCODE -ne 0) { Write-Warning "Windows build invocation exited with code $LASTEXITCODE" }
    }
}


$expectedWindowsNodes = 0
try { $expectedWindowsNodes = [Math]::Max($WindowsNodeCount, 0) } catch { $expectedWindowsNodes = 0 }
$shouldInstallDocker = $false
if ($EnsureWindowsDocker.IsPresent) {
    $shouldInstallDocker = $true
}
elseif ($UseAzureLocal.IsPresent -or $EnableWindows.IsPresent -or $expectedWindowsNodes -gt 0) {
    $shouldInstallDocker = $true
}

if ($shouldInstallDocker) {
    Write-Host "Ensuring Docker Engine is installed on Windows Kubernetes nodes." -ForegroundColor Cyan
    try {
        Install-DockerOnWindowsNodes -KubeConfigPath $KubeConfigFilePath
    }
    catch {
        Write-Warning ("Failed to ensure Docker installation on Windows nodes: {0}" -f $_.Exception.Message)
    }
}


# Render pipeline templates by replacing tokens
Write-Host "Rendering pipeline templates in .azuredevops/pipelines (replacing tokens)"
$pipelineTemplates = Get-ChildItem -Path (Join-Path $repoRoot '.azuredevops\pipelines') -Filter '*.template.yml' -File -Recurse

# Determine default values for useAzureLocal and useOnPremAgents based on bootstrap flags
$useAzureLocalDefault = if ($UseAzureLocal.IsPresent) { 'true' } else { 'false' }
$useOnPremAgentsDefault = if ($UseAzureLocal.IsPresent) { 'true' } else { $UseOnPremAgents }

Write-Host "Pipeline parameter defaults: useAzureLocal=$useAzureLocalDefault, useOnPremAgents=$useOnPremAgentsDefault"

foreach ($tpl in $pipelineTemplates) {
    $text = Get-Content -Raw -Path $tpl.FullName -ErrorAction Stop
    $replacements = @{
        '__ACR_NAME__'                         = $acrShort
        '__AZURE_DEVOPS_ORG_URL__'             = $AzureDevOpsOrgUrl
        '__INSTANCE_NUMBER__'                  = $InstanceNumber
        '__BOOTSTRAP_POOL_NAME__'              = $BootstrapPoolName
        '__KUBECONFIG_AZURE_LOCAL__'           = $KubeconfigAzureLocalPath
        '__KUBECONTEXT_AZURE_LOCAL__'          = $KubeContextAzureLocal
        '__AZURE_SERVICE_CONNECTION__'         = $AzureDevOpsServiceConnectionName
        '__AZURE_DEVOPS_VARIABLE_GROUP__'      = $AzureDevOpsVariableGroup
        '__AZURE_DEVOPS_VARIABLE_GROUP_BASE__' = $AzureDevOpsVariableGroupBase
        '__INSTALL_PIPELINE_NAME__'            = $InstallPipelineName
        '__RUN_ON_POOL_SAMPLE_PIPELINE_NAME__' = $RunOnPoolSamplePipelineName
        '__KUBECONFIG_SECRET_FILE__'           = $KubeConfigSecretFile
        '__SKIP_CONTAINER_REGISTRY__'          = ($ContainerRegistryName -and -not [string]::IsNullOrWhiteSpace($ContainerRegistryName))
        '__UBUNTU_ONPREM_POOL_NAME__'          = $UbuntuOnPremPoolName
        '__WINDOWS_ONPREM_POOL_NAME__'         = $WindowsOnPremPoolName
        '__USE_ONPREM_AGENTS__'                = $useOnPremAgentsDefault
        '__USE_AZURE_LOCAL__'                  = $useAzureLocalDefault
        '__AZURE_DEVOPS_PROJECT_WIKI_NAME__'   = $AzureDevOpsProjectWikiName
    }
    foreach ($k in $replacements.Keys) {
        $v = $replacements[$k]
        if ([string]::IsNullOrWhiteSpace([string]$v)) { $v = '' }
        # Use simple literal string replacement to avoid regex escaping complexities
        $text = $text.Replace($k, [string]$v)
    }
    $outPath = $tpl.FullName -replace '\.template\.yml$', '.yml'
    Write-Host "Writing rendered pipeline: $outPath"
    $text | Out-File -FilePath $outPath -Encoding utf8
}

# Invoke helper to create/update variable group and pipelines (if present)
# The helper will create 6 pipelines:
#   1. deploy-selfhosted-agents-helm (agent deployment)
#   2. uninstall-selfhosted-agents-helm (agent cleanup)
#   3. validate-selfhosted-agents-helm (agent validation)
#   4. weekly-agent-images-refresh (weekly image rebuild)
#   5. run-on-selfhosted-pool-sample-helm (smoke test)
#   6. deploy-aks.yml OR deploy-aks-hci.yml (infrastructure deployment - conditional on UseAzureLocal)
$vgHelper = Join-Path $repoRoot 'scripts\create-variablegroup-and-pipelines.ps1'
if (Test-Path $vgHelper) {
    if ($AutoRepairAzDevOpsExtension) {
        Write-Host 'AutoRepairAzDevOpsExtension enabled: probing azure-devops CLI extension for access issues.'
        try {
            az extension show --name azure-devops 1>$null 2>$null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning 'azure-devops extension not found or inaccessible; attempting install.'
                az extension add --name azure-devops 1>$null 2>$null
            }
            else {
                # Simple permission probe: list projects (ignore output)
                az devops project list 1>$null 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning 'Probe failed (possible permission or corrupt extension). Removing and reinstalling azure-devops extension.'
                    az extension remove --name azure-devops 1>$null 2>$null
                    az extension add --name azure-devops 1>$null 2>$null
                }
            }
        }
        catch {
            Write-Warning ("Extension auto-repair encountered an error: { 0 }" -f $_.Exception.Message)
        }
    }
    Write-Host "Invoking variable-group & pipeline helper: $vgHelper"
    Write-Host "Using AZDO_PAT (masked): $(MaskPat $env:AZDO_PAT)"
    try {
        $vgArgs = @(
            '-NoProfile', '-NonInteractive', '-File', $vgHelper,
            '-OrganizationUrl', $AzureDevOpsOrgUrl,
            '-ProjectName', $AzureDevOpsProject,
            '-RepositoryName', $AzureDevOpsRepo,
            '-AzdoPatSecretName', $AzureDevOpsPatTokenEnvironmentVariableName,
            '-VariableGroupName', $AzureDevOpsVariableGroup,
            '-KubeConfigSecretFile', $KubeConfigSecretFile,
            '-KubeConfigFilePath', $KubeConfigFilePath,
            '-InstallPipelineName', $InstallPipelineName,
            '-UninstallPipelineName', $UninstallPipelineName,
            '-ValidatePipelineName', $ValidatePipelineName,
            '-ImageRefreshPipelineName', $ImageRefreshPipelineName,
            '-RunOnPoolSamplePipelineName', $RunOnPoolSamplePipelineName,
            '-DeployAksInfraPipelineName', $DeployAksInfraPipelineName,
            '-DeployAksHciInfraPipelineName', $DeployAksHciInfraPipelineName
        )
        if ($UseAzureLocal.IsPresent) {
            $vgArgs += '-UseAzureLocal'
        }
        # Stream helper output live to the console while capturing it for later logging.
        # Using Tee-Object lets us display each output line as it arrives and also keep a copy.
        $vgOutput = @()
        & pwsh @vgArgs 2>&1 | Tee-Object -Variable vgOutput | ForEach-Object { Write-Host $_ }
        # Capture the exit code from the child pwsh run. $LASTEXITCODE is set by native processes.
        $rc = $LASTEXITCODE
        if ($rc -ne 0) {
            $joined = $vgOutput -join "`n"
            Write-Warning "create-variablegroup-and-pipelines helper exited with code $rc. Output:`n$joined"
        }
        else {
            Write-Host "Variable group & pipelines helper completed successfully."
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg) { $msg = $msg -replace '\{', '{{' -replace '\}', '}}' }
        Write-Warning ("Failed to invoke variable-group helper: {0}" -f $msg)
    }
}
else {
    Write-Host "Variable-group helper not found at $vgHelper; skipping Azure DevOps provisioning step."
}

# Attempt to invoke helper that will add ACR credentials into the Azure DevOps variable group.
# The CLI-based helper uses Azure CLI commands and AZDO_PAT from environment automatically.
$addAcrScript = Join-Path $repoRoot '.azuredevops\scripts\add-acr-creds-to-variablegroup-cli.ps1'
if (Test-Path $addAcrScript) {
    Write-Host "Invoking add-acr-creds-to-variablegroup-cli helper: $addAcrScript"
    Write-Host "Using AZDO_PAT (masked): $(MaskPat $env:AZDO_PAT) pushed as secret to Azure DevOps"
    $addArgs = @(
        '-AcrName', $acrShort,
        '-OrgUrl', $AzureDevOpsOrgUrl,
        '-Project', $AzureDevOpsProject,
        '-VariableGroupName', $AzureDevOpsVariableGroup
    )
    $addOutput = @()
    & pwsh -NoProfile -NonInteractive -File $addAcrScript @addArgs 2>&1 | Tee-Object -Variable addOutput | ForEach-Object { Write-Host $_ }
    $rc = $LASTEXITCODE
    if ($rc -ne 0) {
        $joined = $addOutput -join "`n"
        Write-Warning "add-acr-creds-to-variablegroup-cli helper exited with code $rc. Output:`n$joined"
    }
    else {
        Write-Host "add-acr-creds-to-variablegroup-cli helper completed successfully."
    }
}
else {
    Write-Host "add-acr-creds-to-variablegroup-cli helper not found at $addAcrScript; skipping."
}

# Post-check: verify the variable group contains ACR_USERNAME and ACR_PASSWORD 
# so pipelines fail fast if secrets weren't created.
try {
    Write-Host "Verifying variable group '$AzureDevOpsVariableGroup' contains ACR_USERNAME and ACR_PASSWORD..."
    $vgListJson = az pipelines variable-group list --org $AzureDevOpsOrgUrl --project $AzureDevOpsProject -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vgListJson)) {
        Write-Warning "Unable to list variable groups using az CLI; skipping ACR variable verification."
    }
    else {
        $vgList = $null
        try { $vgList = $vgListJson | ConvertFrom-Json -ErrorAction Stop } catch { $vgList = $null }
        if (-not $vgList) { Write-Warning "Failed to parse variable groups list JSON; skipping verification." }
        else {
            $vg = $vgList | Where-Object { $_.name -eq $AzureDevOpsVariableGroup }
            if (-not $vg) { Fail "Variable group '$AzureDevOpsVariableGroup' not found in project '$AzureDevOpsProject' (cannot verify ACR variables)." }
            $vgId = $vg.id
            Write-Host "Found variable group id=$vgId; listing variables..."
            $varsJson = az pipelines variable-group variable list --id $vgId --org $AzureDevOpsOrgUrl --project $AzureDevOpsProject -o json 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($varsJson)) { Fail "Failed to list variables for variable group id=$vgId via az CLI." }
            $vars = $null
            try { $vars = $varsJson | ConvertFrom-Json -ErrorAction Stop } catch { $vars = $null }
            if (-not $vars) { Fail "Failed to parse variables JSON for variable group id=$vgId." }
            # Normalize several possible JSON shapes returned by different az/extension versions:
            # 1) An array of { name: 'VAR', ... }
            # 2) An object with a 'variables' map: { variables: { VAR: {...}, ... } }
            # 3) A flat object where each property name is a variable name
            $names = @()
            try {
                if ($vars -is [System.Collections.IEnumerable] -and $vars.Count -gt 0 -and ($vars[0].PSObject.Properties.Name -contains 'name')) {
                    # Shape 1: array of objects with 'name'
                    $names = $vars | ForEach-Object { $_.name }
                }
                elseif ($vars -and $vars.PSObject.Properties.Match('variables').Count -gt 0) {
                    # Shape 2: object with 'variables' map
                    $map = $vars.variables
                    if ($map) {
                        # map is usually an object with properties named after variables
                        $names = $map.PSObject.Properties | ForEach-Object { $_.Name }
                    }
                }
                else {
                    # Shape 3: treat top-level property names as variable names
                    $names = $vars.PSObject.Properties | ForEach-Object { $_.Name }
                }
            }
            catch { $names = @() }
            $hasUser = $names -contains 'ACR_USERNAME'
            $hasPass = $names -contains 'ACR_PASSWORD'
            if (-not $hasUser -or -not $hasPass) {
                $missing = @()
                if (-not $hasUser) { $missing += 'ACR_USERNAME' }
                if (-not $hasPass) { $missing += 'ACR_PASSWORD' }
                Fail (("Variable group '{0}' is missing required ACR variables. Present: { 1 }. Missing: { 2 }") -f $AzureDevOpsVariableGroup, ($names -join ', '), ($missing -join ', '))
            }
            else {
                Write-Host "Verified: ACR_USERNAME and ACR_PASSWORD exist in variable group (id=$vgId)."
            }
        }
    }
}
catch {
    Fail ("ACR variable verification failed: { 0 }" -f $_.Exception.Message)
}

Write-Green "Bootstrap and build run completed. ACR: $acrShort, AKS: $aksName, RG: $ResourceGroupName"
Write-Green "Remember to commit and push your updated pipeline .yml files in .azuredevops/pipelines BEFORE running any of the created pipelines."
exit 0
