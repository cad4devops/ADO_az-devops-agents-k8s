<#
.azuredevops/scripts/deploy-selfhosted-agents-helm.ps1

This script performs the same high-level steps as the pipeline
`deploy-selfhosted-agents-helm.yml` so you can run it locally for
development and debugging.

Usage (example):
  pwsh ./.azuredevops/scripts/deploy-selfhosted-agents-helm.ps1 \
    -Kubeconfig C:\path\to\kubeconfig \
    -InstanceNumber 003 \
    -AcrName cragents003c66i4n7btfksg \
    -AcrUsername '<username>' -AcrPassword '<password>' \
    -EnsureAzDoPools

Parameters:
- Kubeconfig: path to kubeconfig file (or set KUBECONFIG env var)
- DeployLinux, DeployWindows: switches to control which platforms to deploy
- WindowsVersion, LinuxImageVariant, AcrName, InstanceNumber
- AcrUsername/AcrPassword: optional credentials to create a docker-registry secret named 'regsecret' in the release namespaces
- EnsureAzDoPools: if set, the script will try to create Azure DevOps agent pools using AZDO_PAT env var

This script is intentionally conservative: it will not enable ACR admin or create cloud resources beyond calling Azure CLI if requested.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $InstanceNumber, #'003'
    [Parameter(Mandatory = $false)] [string] $Kubeconfig = "aks-ado-agents-$InstanceNumber",
    [Parameter(Mandatory = $false)] [string] $KubeconfigAzureLocal, #"workload-cluster-003-kubeconfig.yaml"
    [Parameter(Mandatory = $false)] [string] $KubeconfigFolder,
    [Parameter(Mandatory = $false)] [string] $DefaultLocalKubeconfig = "config\workload-cluster-$InstanceNumber-kubeconfig.yaml",
    [Parameter(Mandatory = $false)] [switch] $DeployLinux = $true,
    [Parameter(Mandatory = $false)] [switch] $DeployWindows = $true,
    [Parameter(Mandatory = $false)] [string] $WindowsVersion = '2022',
    [Parameter(Mandatory = $false)] [ValidateSet('docker', 'dind', 'ubuntu22')] [string] $LinuxImageVariant = 'docker',
    [Parameter(Mandatory = $true)] [string] $AcrName, #'cragents003c66i4n7btfksg'
    [Parameter(Mandatory = $true)] [string] $AzureDevOpsOrgUrl, #'https://dev.azure.com/cad4devops',    
    [Parameter(Mandatory = $false)] [string] $HelmTimeout = '2m',
    [Parameter(Mandatory = $false)] [switch] $UseAzureLocal,
    [Parameter(Mandatory = $false)] [string] $KubeContext = "aks-ado-agents-$InstanceNumber",
    [Parameter(Mandatory = $false)] [string] $KubeContextAzureLocal, #"workload-cluster-003-admin@workload-cluster-003"
    [Parameter(Mandatory = $false)] [string] $AksResourceGroup = "rg-aks-ado-agents-$InstanceNumber",
    [Parameter(Mandatory = $false)] [string] $AksClusterName = "aks-ado-agents-$InstanceNumber",
    [Parameter(Mandatory = $false)] [string] $AcrUsername,
    [Parameter(Mandatory = $false)] [string] $AcrPassword,
    # NOTE: we accept only AzureDevOpsOrgUrl now (legacy alias removed)
    [Parameter(Mandatory = $false)] [string] $AzDevOpsToken,
    [Parameter(Mandatory = $false)] [string] $AzDevOpsPool,
    [Parameter(Mandatory = $false)] [string] $AzDevOpsPoolLinux,
    [Parameter(Mandatory = $false)] [string] $AzDevOpsPoolWindows,
    [Parameter(Mandatory = $false)] [switch] $WriteValuesOnly,
    [Parameter(Mandatory = $false)] [switch] $EnsureAzDoPools
)

function Fail([string]$msg) { Write-Error $msg; exit 1 }

Write-Host "Starting local deploy script (instance=$InstanceNumber)"

# Cross-platform green output helper (same behavior as in uninstall helper)
function Write-Green([string]$msg) {
    try {
        if ($IsWindows) { Write-Host -ForegroundColor Green $msg }
        else { Write-Host "`e[32m$msg`e[0m" }
    }
    catch { Write-Host $msg }
}

# If running in Azure-local/on-prem mode, require the caller to supply local kubeconfig and context
# and an explicit bootstrap pool name so downstream operations have the information they need.
if ($UseAzureLocal.IsPresent) {
    $missing = @()
    if (-not $KubeconfigAzureLocal -or [string]::IsNullOrWhiteSpace($KubeconfigAzureLocal)) { $missing += 'KubeconfigAzureLocal' }
    if (-not $KubeContextAzureLocal -or [string]::IsNullOrWhiteSpace($KubeContextAzureLocal)) { $missing += 'KubeContextAzureLocal' }
    if ($missing.Count -gt 0) {
        Fail ("When -UseAzureLocal is set the following parameters must be provided and non-empty: {0}" -f ($missing -join ', '))
    }
}

if (-not $WriteValuesOnly.IsPresent) {
    # Resolve effective kubeconfig folder (default to C:\Users\<user>\.kube)
    $userProfile = $env:USERPROFILE; if (-not $userProfile) { $userProfile = $env:HOME }
    if ($KubeconfigFolder) { $effectiveKubeFolder = $KubeconfigFolder } elseif ($userProfile) { $effectiveKubeFolder = Join-Path $userProfile '.kube' } else { $effectiveKubeFolder = Join-Path ([System.IO.Path]::GetTempPath()) '.kube' }

    # Choose which kubeconfig parameter to prefer based on -UseAzureLocal.
    # When running against an Azure-local/on-prem workload cluster the caller may pass
    # -KubeconfigAzureLocal; otherwise -Kubeconfig is the common param. Centralize the
    # effective parameter so downstream code needs only consult one variable.
    $effectiveKubeParam = if ($UseAzureLocal.IsPresent) { $KubeconfigAzureLocal } else { $Kubeconfig }
    $effectiveKubeParamName = if ($UseAzureLocal.IsPresent) { 'KubeconfigAzureLocal' } else { 'Kubeconfig' }

    # Debug: show which kubeconfig parameter and mode we observed (helps pipeline logs)
    Write-Host ("DEBUG: UseAzureLocal.IsPresent={0}; effectiveKubeParamName={1}; effectiveKubeParam='{2}'" -f $UseAzureLocal.IsPresent, $effectiveKubeParamName, ($effectiveKubeParam -replace '\\', '/'))

    # If the caller provided an explicit kubeconfig (via the selected param) and it exists, prefer it.
    if ($effectiveKubeParam) {
        try { $resolved = (Resolve-Path -Path $effectiveKubeParam -ErrorAction SilentlyContinue).Path } catch { $resolved = $null }
        if ($resolved) {
            $env:KUBECONFIG = $resolved
            Write-Host ("Using provided -{0}: {1}" -f $effectiveKubeParamName, ${env:KUBECONFIG})
        }
        else {
            Write-Host ("-{0} was provided ('{1}') but the path was not found; falling back to other resolution." -f $effectiveKubeParamName, $effectiveKubeParam)
        }
    }

    # If a previous pipeline step (AzureCLI task or secure-file downloader) already set KUBECONFIG
    # prefer that and skip attempting to call az again (the AzureCLI task does not leave a
    # persistent az login for subsequent tasks). This makes the script resilient when the
    # pipeline obtains credentials via an earlier task and writes KUBECONFIG using the
    # Write-Host "##vso[task.setvariable variable=KUBECONFIG]..." mechanism.
    if ($env:KUBECONFIG -and (Test-Path $env:KUBECONFIG)) {
        Write-Host "KUBECONFIG already set to $env:KUBECONFIG (from previous step); skipping az fetch."
    }
    elseif (-not $UseAzureLocal.IsPresent) {
        # Non-local: always fetch credentials from AKS via az CLI and fail fast on errors
        Write-Host 'UseAzureLocal not set; fetching AKS credentials via az CLI.'
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Fail "Azure CLI (az) not found in PATH. Install Azure CLI or run with -UseAzureLocal and provide a local kubeconfig." }
        if (-not $AksResourceGroup -or -not $AksClusterName) { Fail "To fetch AKS credentials the script requires -AksResourceGroup and -AksClusterName when -UseAzureLocal is not set." }
        try { $acct = az account show --query id -o tsv 2>$null } catch { Fail "Failed to query Azure account (az account show). Ensure az is logged in. Error: $($_.Exception.Message)" }
        if (-not $acct) { Fail 'No Azure subscription found in az CLI context. Login (az login) or set subscription before running this script.' }

        $tempBase = if ($env:AGENT_TEMPDIRECTORY) { $env:AGENT_TEMPDIRECTORY } else { [System.IO.Path]::GetTempPath() }
        $kubeTmp = Join-Path $tempBase 'kubeconfig'
        Write-Host "Fetching AKS credentials for cluster '$AksClusterName' in resource group '$AksResourceGroup' into $kubeTmp"
        try { & az aks get-credentials --resource-group $AksResourceGroup --name $AksClusterName --file $kubeTmp --overwrite-existing } catch { Fail "az aks get-credentials failed: $($_.Exception.Message)" }
        if (-not (Test-Path $kubeTmp)) { Fail "az aks get-credentials did not produce a kubeconfig at expected path: $kubeTmp" }
        $env:KUBECONFIG = (Resolve-Path $kubeTmp).Path
        Write-Host "Set KUBECONFIG to $env:KUBECONFIG"
    }
    else {
        # Local mode: resolve local kubeconfig by joining folder and filename using the
        # selected parameter (KubeconfigAzureLocal when -UseAzureLocal, else Kubeconfig).
        if ($effectiveKubeParam) {
            try { $isAbs = [System.IO.Path]::IsPathRooted($effectiveKubeParam) } catch { $isAbs = $false }
            if ($isAbs) { $resolvedLocalKube = $effectiveKubeParam } else { $resolvedLocalKube = Join-Path $effectiveKubeFolder $effectiveKubeParam }
        }
        else { $resolvedLocalKube = Join-Path $effectiveKubeFolder $DefaultLocalKubeconfig }

        if (Test-Path $resolvedLocalKube) {
            $env:KUBECONFIG = (Resolve-Path $resolvedLocalKube).Path
            Write-Host ("KUBECONFIG not provided; using local kubeconfig: {0}" -f ${env:KUBECONFIG})
        }
        else {
            $legacy = Join-Path $effectiveKubeFolder 'config'
            if (Test-Path $legacy) { $env:KUBECONFIG = (Resolve-Path $legacy).Path; Write-Host ("Using legacy kubeconfig at {0}" -f ${env:KUBECONFIG}) }
            else { Fail ("Local kubeconfig not found at either {0} or {1}. Provide -{2} or ensure the default exists." -f $resolvedLocalKube, $legacy, $effectiveKubeParamName) }
        }
    }

    # verify tools
    foreach ($tool in @('kubectl', 'helm')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Fail "$tool is not installed or not on PATH. Please install it and retry."
        }
    }

    # If KUBECONFIG was set by this script (az or secure-file), explicitly select a context
    # from that kubeconfig so kubectl commands target the intended cluster. Choose the first
    # context found in the kubeconfig file as a reasonable default.
    try {
        if ($env:KUBECONFIG) {
            $ctxRaw = (& kubectl --kubeconfig $env:KUBECONFIG config view -o jsonpath="{.contexts[*].name}" 2>$null) -join ' '
            $ctxs = @()
            if ($ctxRaw) { $ctxs = ($ctxRaw -split '\s+') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } }
            if ($ctxs.Count -gt 0) {
                $firstCtx = $ctxs[0]
                try { & kubectl --kubeconfig $env:KUBECONFIG config use-context $firstCtx > $null 2>&1; Write-Host "Set kubectl current-context to $firstCtx (from $env:KUBECONFIG)" }
                catch { Write-Warning "Failed to set kubectl current-context to ${firstCtx}: $($_.Exception.Message)" }
            }
            else {
                Write-Warning "No contexts found in kubeconfig at $env:KUBECONFIG; leaving default kubectl context as-is."
            }
        }
        else {
            Write-Host "KUBECONFIG not set; kubectl will use the default context on the agent."
        }
    }
    catch {
        Write-Warning "Failed while attempting to select kubectl context from KUBECONFIG: $($_.Exception.Message)"
    }

    # Confirm we can talk to the cluster early
    try {
        Write-Host 'Verifying cluster access with: kubectl get nodes -o wide'
        kubectl get nodes -o wide | Out-Null
        Write-Host 'Cluster access verified.'
    }
    catch {
        Fail "Failed to list nodes from cluster (kubectl get nodes -o wide). Ensure KUBECONFIG is correct and cluster is reachable. Error: $($_.Exception.Message)"
    }

    # Enforce expected kubectl context if caller provided one.
    try {
        if ($UseAzureLocal.IsPresent -and $KubeContextAzureLocal) { $expectedCtx = $KubeContextAzureLocal }
        elseif ($KubeContext) { $expectedCtx = $KubeContext }
        else { $expectedCtx = $null }

        if ($expectedCtx) {
            $current = (& kubectl config current-context 2>$null) -as [string]
            if (-not $current) { Fail "No current kubectl context detected but expected '$expectedCtx'. Ensure KUBECONFIG/context is configured." }
            if ($current.Trim() -ne $expectedCtx.Trim()) { Fail "Current kubectl context '$current' does not match expected context '$expectedCtx'. Aborting." }
            Write-Green "Current kubectl context '$current' matches expected context '$expectedCtx'."
        }
    }
    catch {
        Fail "Error while validating current kubectl context: $($_.Exception.Message)"
    }
}
else { Write-Host 'WriteValuesOnly set: skipping kubeconfig handling and tool checks' }

# verify tools (skip when only writing values)
if (-not $WriteValuesOnly.IsPresent) {
    foreach ($tool in @('kubectl', 'helm')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Fail "$tool is not installed or not on PATH. Please install it and retry."
        }
    }
}
# Populate ACR credentials from environment variables if not provided as parameters.
# Behavior: if either an ACR username or password is supplied (via parameter or env), require both to be present.
# If neither is supplied (and env vars absent), we continue and Helm will skip creating the regsecret.
if (-not $AcrUsername -and $env:ACR_ADO_USERNAME) {
    $AcrUsername = $env:ACR_ADO_USERNAME
    Write-Host "Using ACR username from env ACR_ADO_USERNAME"
}
if (-not $AcrPassword -and $env:ACR_ADO_PASSWORD) {
    $AcrPassword = $env:ACR_ADO_PASSWORD
    Write-Host "Using ACR password from env ACR_ADO_PASSWORD"
}

# Defensive: pipelines sometimes pass literal macro strings like '$(ACR_USERNAME)' when variables
# are missing or not expanded in the caller context. Detect common unresolved macro patterns and
# prefer the runtime environment variables (ACR_USERNAME/ACR_PASSWORD) when available.
if ($AcrUsername -and ($AcrUsername -match '\$\(|\$\{')) {
    if ($env:ACR_USERNAME) {
        Write-Host "Notice: AcrUsername contains unresolved macro; using runtime env ACR_USERNAME instead"
        $AcrUsername = $env:ACR_USERNAME
    }
    elseif ($env:ACR_ADO_USERNAME) {
        Write-Host "Notice: AcrUsername contains unresolved macro; using fallback env ACR_ADO_USERNAME instead"
        $AcrUsername = $env:ACR_ADO_USERNAME
    }
}
if ($AcrPassword -and ($AcrPassword -match '\$\(|\$\{')) {
    if ($env:ACR_PASSWORD) {
        Write-Host "Notice: AcrPassword contains unresolved macro; using runtime env ACR_PASSWORD instead"
        $AcrPassword = $env:ACR_PASSWORD
    }
    elseif ($env:ACR_ADO_PASSWORD) {
        Write-Host "Notice: AcrPassword contains unresolved macro; using fallback env ACR_ADO_PASSWORD instead"
        $AcrPassword = $env:ACR_ADO_PASSWORD
    }
}

# If either value is set (param or env), require both to avoid proceeding with incomplete credentials.
if ( ($AcrUsername -or $AcrPassword) -and -not ($AcrUsername -and $AcrPassword) ) {
    Fail "Both -AcrUsername and -AcrPassword must be provided (or set ACR_ADO_USERNAME and ACR_ADO_PASSWORD environment variables)."
}
# Allow using AZDO_PAT env var as a fallback for AzDevOpsToken when validating parameters
$effectiveAzDoToken = $AzDevOpsToken
if (-not $effectiveAzDoToken -and $env:AZDO_PAT) { $effectiveAzDoToken = $env:AZDO_PAT }
if ( ($effectiveAzDoToken -or $AzDevOpsPool -or $AzDevOpsPoolLinux -or $AzDevOpsPoolWindows) -and -not ($AzureDevOpsOrgUrl -and $effectiveAzDoToken) ) {
    Fail "If you provide any AzDevOps credential parameter you must provide both -AzureDevOpsOrgUrl and AzDevOpsToken (or set AZDO_PAT env var)"
}

# Decide per-OS pool values (backwards compatible with -AzDevOpsPool)
$poolLinux = if ($AzDevOpsPoolLinux) { $AzDevOpsPoolLinux } elseif ($AzDevOpsPool) { $AzDevOpsPool } else { $null }
$poolWindows = if ($AzDevOpsPoolWindows) { $AzDevOpsPoolWindows } elseif ($AzDevOpsPool) { $AzDevOpsPool } else { $null }

# If no explicit pool names were provided, default to derived names. When running
# against a local/on-prem cluster (UseAzureLocal) include the OnPrem marker so pools
# are clearly differentiated from cloud-hosted pools.
if ((-not $poolLinux) -and $InstanceNumber) {
    if ($UseAzureLocal.IsPresent) { $poolLinux = "KubernetesPoolOnPremLinux$InstanceNumber" } else { $poolLinux = "KubernetesPoolLinux$InstanceNumber" }
    Write-Host "No explicit Linux pool name provided; defaulting to $poolLinux"
}
if ((-not $poolWindows) -and $InstanceNumber) {
    if ($UseAzureLocal.IsPresent) { $poolWindows = "KubernetesPoolOnPremWindows$InstanceNumber" } else { $poolWindows = "KubernetesPoolWindows$InstanceNumber" }
    Write-Host "No explicit Windows pool name provided; defaulting to $poolWindows"
}

# Helper to safely quote YAML single-quoted scalars (escape any single quotes)
function QuoteYaml([string]$s) {
    if ($null -eq $s) { return "''" }
    $escaped = $s -replace "'", "''"
    return "'" + $escaped + "'"
}

# ensure Azure DevOps agent pools (optional)
function Ensure-Pool([string]$orgUrl, [string]$pat, [string]$poolName) {
    $authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $pat))
    $headers = @{ Authorization = $authHeader }
    $apiVersion = '7.1-preview.1'
    $getUri = "$orgUrl/_apis/distributedtask/pools?poolName=$([Uri]::EscapeDataString($poolName))&api-version=$apiVersion"
    try {
        $resp = Invoke-RestMethod -Method Get -Uri $getUri -Headers $headers -ErrorAction Stop
        if ($resp.count -gt 0) { Write-Host "Pool $poolName exists (id=$($resp.value[0].id))"; return $resp.value[0].id }
    }
    catch {
        # continue to try create
    }
    Write-Host "Creating pool $poolName"
    $createUri = "$orgUrl/_apis/distributedtask/pools?api-version=$apiVersion"
    $body = @{ name = $poolName } | ConvertTo-Json -Compress
    $created = Invoke-RestMethod -Method Post -Uri $createUri -Headers ($headers + @{ 'Content-Type' = 'application/json' }) -Body $body -ErrorAction Stop
    Write-Host "Created pool id=$($created.id)"
    return $created.id
}

<#
Ensure Azure DevOps agent pools exist before deploying the chart.
Behavior:
 - If -EnsureAzDoPools is present, use AZDO_PAT env var (pipeline behavior).
 - If AzDevOpsToken and AzDevOpsUrl/AzureDevOpsOrgUrl are provided to the script, use them (convenience for CLI callers).
 - Prefer AzDevOpsToken param if provided, otherwise fall back to $env:AZDO_PAT.
#>
$shouldEnsurePools = $false
# If the caller explicitly requested pool creation, honor it. Additionally, if we have an
# effective AzDo PAT available (via -AzDevOpsToken or AZDO_PAT env) and an org URL, ensure
# pools are created automatically prior to Helm deployment to avoid agent registration errors.
if ($EnsureAzDoPools.IsPresent) { $shouldEnsurePools = $true }
if (-not $shouldEnsurePools -and $effectiveAzDoToken -and $AzureDevOpsOrgUrl) { $shouldEnsurePools = $true }
if ($shouldEnsurePools) {
    # Choose PAT: prefer the already-computed effective token which may come from param or env
    $pat = $effectiveAzDoToken
    if (-not $pat) { Write-Warning 'No AzDo PAT supplied (AzDevOpsToken param or AZDO_PAT env); skipping pool creation' } else {
        # Use the canonical Azure DevOps org URL parameter
        $org = $AzureDevOpsOrgUrl
        if (-not $org) { Write-Warning 'No Azure DevOps org URL available; skipping pool creation' } else {
            if ($DeployLinux) { Ensure-Pool $org $pat $poolLinux | Out-Null }
            if ($DeployWindows) { Ensure-Pool $org $pat $poolWindows | Out-Null }
        }
    }
}

# Install/ensure KEDA
Write-Host 'Adding KEDA Helm repo and installing KEDA...'
helm repo add kedacore https://kedacore.github.io/charts 2>$null || $true
helm repo update
helm upgrade --install keda kedacore/keda --namespace keda --create-namespace --wait --timeout 5m
Write-Host 'KEDA install ensured.'

# build values override
$enabledLinux = $DeployLinux.IsPresent ? 'true' : 'false'
$enabledWindows = $DeployWindows.IsPresent ? 'true' : 'false'
switch ($LinuxImageVariant) {
    'ubuntu22' { $linuxRepo = "$AcrName.azurecr.io/linux-sh-agent-ubuntu22" }
    'dind' { $linuxRepo = "$AcrName.azurecr.io/linux-sh-agent-dind" }
    default { $linuxRepo = "$AcrName.azurecr.io/linux-sh-agent-docker" }
}
$winRepo = "$AcrName.azurecr.io/windows-sh-agent-$WindowsVersion"

$yamlLines = @()

# If Acr credentials were provided, build regsecret block with decoded JSON so Helm stringData is valid
if ($AcrUsername -and $AcrPassword) {
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$AcrUsername`:$AcrPassword"))
    $dockerConfigObj = @{ auths = @{} }
    $dockerConfigObj.auths.Add("$AcrName.azurecr.io", @{ auth = $auth; username = $AcrUsername; password = $AcrPassword })
    $dockerConfigJson = ConvertTo-Json $dockerConfigObj -Depth 10
    # Compact JSON onto a single line so Helm/ Kubernetes treat it as a single string value
    $dockerConfigJson = ($dockerConfigJson -replace "\r?\n", "") -replace "\s+", " "

    $yamlLines += 'regsecret:'
    $yamlLines += '  data:'
    # Put the entire JSON as a single quoted YAML scalar so it remains a string (not parsed into an object)
    $yamlLines += ('    DOCKER_CONFIG_JSON_VALUE: ' + (QuoteYaml $dockerConfigJson))
}
else {
    # Explicitly override chart default to an empty value so Helm won't create the regsecret when creds are not provided
    $yamlLines += 'regsecret:'
    $yamlLines += '  data:'
    $yamlLines += ('    DOCKER_CONFIG_JSON_VALUE: ' + (QuoteYaml ""))
}

$yamlLines += 'linux:'
$yamlLines += ('  enabled: ' + $enabledLinux)
$yamlLines += '  deploy:'
$yamlLines += '    container:'
$yamlLines += ('      image: ' + ($linuxRepo + ':latest'))
$yamlLines += '      pullPolicy: IfNotPresent'
$yamlLines += 'windows:'
$yamlLines += ('  enabled: ' + $enabledWindows)
$yamlLines += '  deploy:'
$yamlLines += '    container:'
$yamlLines += ('      image: ' + ($winRepo + ':latest'))
$yamlLines += '      pullPolicy: IfNotPresent'
$yamlLines += 'common:'
$yamlLines += ('  instance: ' + $InstanceNumber)
$yamlLines += ('linuxNamespace: az-devops-linux-' + $InstanceNumber)
$yamlLines += ('windowsNamespace: az-devops-windows-' + $InstanceNumber)

# If AzDevOps credentials were provided, add secret data for linux and windows so Helm creates the azdevops secret
# Accept either -AzDevOpsUrl (legacy) or -AzureDevOpsOrgUrl (preferred) as the organization URL
# Normalize to canonical $AzureDevOpsOrgUrl variable for downstream use
$orgUrl = $null
if ($AzDevOpsUrl) {
    # map legacy name to canonical variable if not already set
    if (-not $AzureDevOpsOrgUrl) { $AzureDevOpsOrgUrl = $AzDevOpsUrl }
    $orgUrl = $AzureDevOpsOrgUrl
}
elseif ($AzureDevOpsOrgUrl) {
    $orgUrl = $AzureDevOpsOrgUrl
}
# Validate/normalize the org URL early. Decode base64 heuristically and ensure it looks like a valid http(s) URL.
function Is-ValidHttpUrl([string]$u) {
    if (-not $u) { return $false }
    try {
        $uri = [Uri]::new($u)
        if ($uri.Scheme -match '^https?$') { return $true } else { return $false }
    }
    catch { return $false }
}
function Maybe-DecodeBase64([string]$s) {
    if (-not $s) { return $s }
    # Heuristic: if the value looks like base64 (long alnum + / + + and optional = padding) try to decode
    if ($s -match '^[A-Za-z0-9+/=]{16,}$') {
        try {
            $bytes = [System.Convert]::FromBase64String($s)
            $dec = [System.Text.Encoding]::UTF8.GetString($bytes)
            if ($dec -match '^https?://') { return $dec }
        }
        catch { }
    }
    return $s
}

if ($orgUrl) {
    $decoded = Maybe-DecodeBase64 $orgUrl
    if ($decoded -ne $orgUrl) {
        Write-Host "Decoded Azure DevOps org URL from base64-looking input"
        $orgUrl = $decoded
    }
    if (-not (Is-ValidHttpUrl $orgUrl)) {
        Fail "Azure DevOps org URL appears invalid or malformed: '$orgUrl'. Provide a full https://... URL via -AzureDevOpsOrgUrl or ensure any base64 value decodes to a valid URL."
    }
}
if ($orgUrl -and $effectiveAzDoToken) {
    # Use the effective token (parameter or AZDO_PAT env var) when emitting the Helm values so
    # the chart creates the azdevops secret even when AZDO_PAT is used in the environment.
    $tokenToUse = $effectiveAzDoToken

    # Linux secret
    $yamlLines += 'secretlinux:'
    $yamlLines += ('  name: azdevops')
    $yamlLines += '  data:'
    if ($poolLinux) { $yamlLines += ('    AZP_POOL_VALUE: ' + (QuoteYaml $poolLinux)) }
    $yamlLines += ('    AZP_TOKEN_VALUE: ' + (QuoteYaml $tokenToUse))
    $yamlLines += ('    AZP_URL_VALUE: ' + (QuoteYaml $orgUrl))

    # Windows secret
    $yamlLines += 'secretwindows:'
    $yamlLines += ('  name: azdevops')
    $yamlLines += '  data:'
    if ($poolWindows) { $yamlLines += ('    AZP_POOL_VALUE: ' + (QuoteYaml $poolWindows)) }
    $yamlLines += ('    AZP_TOKEN_VALUE: ' + (QuoteYaml $tokenToUse))
    $yamlLines += ('    AZP_URL_VALUE: ' + (QuoteYaml $orgUrl))
}

# If we have AzDO info available (via token or env AZDO_PAT) try to resolve pool IDs for KEDA ScaledObject triggers
$patForPools = if ($AzDevOpsToken) { $AzDevOpsToken } elseif ($env:AZDO_PAT) { $env:AZDO_PAT } else { $null }
if ($patForPools -and $orgUrl) {
    # Initialize pool ID variables so referencing them is safe under StrictMode
    $linuxPoolId = $null
    $windowsPoolId = $null
    try {
        Write-Host "Resolving Azure DevOps pool IDs for pool names: linux='$poolLinux' windows='$poolWindows'"
        $authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $patForPools))
        $headers = @{ Authorization = $authHeader }
        # Query pools by name; use the distributedtask/pools endpoint
        if ($poolLinux) {
            $q = "$orgUrl/_apis/distributedtask/pools?poolName=$([Uri]::EscapeDataString($poolLinux))&api-version=7.1-preview.1"
            $resp = Invoke-RestMethod -Method Get -Uri $q -Headers $headers -ErrorAction Stop
            if ($resp.count -gt 0) { $linuxPoolId = $resp.value[0].id }
        }
        if ($poolWindows) {
            $q = "$orgUrl/_apis/distributedtask/pools?poolName=$([Uri]::EscapeDataString($poolWindows))&api-version=7.1-preview.1"
            $resp = Invoke-RestMethod -Method Get -Uri $q -Headers $headers -ErrorAction Stop
            if ($resp.count -gt 0) { $windowsPoolId = $resp.value[0].id }
        }
        # Emit poolID section -- empty strings when unresolved
        $yamlLines += 'poolID:'
        if ($linuxPoolId) { $yamlLines += ('  linux: ' + $linuxPoolId) } else { $yamlLines += '  linux: ""' }
        if ($windowsPoolId) { $yamlLines += ('  windows: ' + $windowsPoolId) } else { $yamlLines += '  windows: ""' }
        Write-Host "Resolved pool IDs: linux=$linuxPoolId windows=$windowsPoolId"
    }
    catch {
        Write-Warning "Failed to resolve pool IDs from Azure DevOps: $($_.Exception.Message)"
        # still emit empty poolID keys to avoid template errors
        $yamlLines += 'poolID:'
        $yamlLines += '  linux: ""'
        $yamlLines += '  windows: ""'
    }
}
else {
    # No AzDO credentials; emit empty poolID entries so the chart compiles but KEDA won't be functional until set
    $yamlLines += 'poolID:'
    $yamlLines += '  linux: ""'
    $yamlLines += '  windows: ""'
}

$tmpDir = $null
# Resolve a cross-platform temporary directory. Prefer Azure Pipelines provided Agent temp directory when available,
# otherwise fall back to .NET's GetTempPath(), and finally to $env:TEMP for maximum compatibility.
if ($env:AGENT_TEMPDIRECTORY) { $tmpDir = $env:AGENT_TEMPDIRECTORY }
elseif ([System.IO.Path]::GetTempPath()) { $tmpDir = [System.IO.Path]::GetTempPath() }
elseif ($env:TEMP) { $tmpDir = $env:TEMP }
else { Fail 'Could not determine a temporary directory (AGENT_TEMPDIRECTORY, GetTempPath() and TEMP are all unavailable).' }

# Normalize to an existing directory (create if necessary)
try {
    if (-not (Test-Path -Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir | Out-Null }
}
catch {
    Fail ("Failed to create or access temporary directory: $tmpDir. Error: $($_.Exception.Message)")
}

$yamlPath = Join-Path -Path $tmpDir -ChildPath "helm-values-override-$InstanceNumber.yaml"
$yamlLines | Out-File -FilePath $yamlPath -Encoding utf8
Write-Host "Wrote Helm values override to $yamlPath"
# Helper: mask sensitive values in YAML for safe diagnostics
function Mask-SensitiveYaml([string]$text) {
    if (-not $text) { return $text }

    # Here-strings must have their closing marker at column 1; keep these unindented.
    $patternToken = @'
(?mi)^(\s*AZP_TOKEN_VALUE:\s*)(?:'[^']*'|"[^"]*"|[^\r\n]+)
'@

    $patternDocker = @'
(?mi)^(\s*DOCKER_CONFIG_JSON_VALUE:\s*)(?:'[^']*'|"[^"]*"|[^\r\n]+)
'@

    $patternPass = @'
(?mi)^(\s*password:\s*)(?:'[^']*'|"[^"]*"|[^\r\n]+)
'@

    $patternAzpToken = @'
(?mi)^(\s*(?:AZP_TOKEN|AZP_TOKEN_VALUE)\s*:\s*)(?:'[^']*'|"[^"]*"|[^\r\n]+)
'@

    $patternPersonal = @'
(?mi)^(\s*personalAccessToken\s*:\s*)(?:'[^']*'|"[^"]*"|[^\r\n]+)
'@

    $patternDockerInlinePass = @'
(?mi)("password"\s*:\s*")([^"]+)(")
'@

    $patternDockerInlineAuth = @'
(?mi)("auth"\s*:\s*")([^"]+)(")
'@

    # Match auth values that may be unquoted (YAML-style) or are long base64-like tokens.
    # Use a lookahead so we don't require capturing a trailing comma/newline which may be absent
    $patternAuthNoQuotes = @'
(?mi)^(\s*auth\s*:\s*)([A-Za-z0-9+/=]{8,})(?=\s*[,\r\n]|$)
'@

    # Match occurrences where JSON keys/values are escaped in logs (e.g. \"auth\": \"...\")
    $patternEscapedJsonAuth = @'
(?mi)\\?"auth\\?"\s*:\s*\\?"([A-Za-z0-9+/=]{8,})\\?"
'@

    # Match dockerconfigjson when embedded as a base64-ish string in JSON output
    $patternDockerConfigJsonValue = @'
(?mi)("dockerconfigjson"\s*:\s*")([A-Za-z0-9+/=]{8,})(")
'@

    $opts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    $text = [regex]::Replace($text, $patternToken, '${1}(redacted)', $opts)
    $text = [regex]::Replace($text, $patternDocker, '${1}(redacted)', $opts)
    $text = [regex]::Replace($text, $patternPass, '${1}(redacted)', $opts)
    $text = [regex]::Replace($text, $patternAzpToken, '${1}(redacted)', $opts)
    $text = [regex]::Replace($text, $patternPersonal, '${1}(redacted)', $opts)
    $text = [regex]::Replace($text, $patternDockerInlinePass, '${1}(redacted)${3}', $opts)
    $text = [regex]::Replace($text, $patternDockerInlineAuth, '${1}(redacted)${3}', $opts)
    $text = [regex]::Replace($text, $patternAuthNoQuotes, '${1}(redacted)', $opts)
    $text = [regex]::Replace($text, $patternEscapedJsonAuth, '"auth": "(redacted)"', $opts)
    $text = [regex]::Replace($text, $patternDockerConfigJsonValue, '${1}(redacted)${3}', $opts)
    return $text
}


# Diagnostic: print a masked copy of the generated values file so logs contain debug info but not secrets
Write-Host '--- helm values override (masked diagnostic) ---'
$vals = Get-Content -Path $yamlPath -Raw
Write-Host (Mask-SensitiveYaml $vals)
Write-Host '--- end helm values override ---'

# If running inside a pipeline, copy the generated values file into the pipeline's
# artifact staging directory so the PublishPipelineArtifact task can find it.
if ($env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
    try {
        if (-not (Test-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY)) {
            New-Item -ItemType Directory -Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY | Out-Null
        }
        $dest = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'helm-values-override.yaml'
        Copy-Item -Path $yamlPath -Destination $dest -Force
        Write-Host "Copied Helm values override to $dest for pipeline artifact publish"
    }
    catch {
        Write-Warning "Failed to copy helm values override to Build.ArtifactStagingDirectory: $($_.Exception.Message)"
    }
}

if ($WriteValuesOnly.IsPresent) {
    Write-Host "WriteValuesOnly set - exiting after creating values file: $yamlPath"
    exit 0
}

# Ensure namespaces (do not create a separate release namespace anymore)
# We create only the per-OS namespaces; the Helm release will be installed into one of them.
$linuxNs = "az-devops-linux-$InstanceNumber"
$winNs = "az-devops-windows-$InstanceNumber"
$namespaces = @($linuxNs, $winNs)
# Choose release namespace: prefer Linux if Linux is being deployed, otherwise Windows
$releaseNamespace = if ($DeployLinux.IsPresent) { $linuxNs } elseif ($DeployWindows.IsPresent) { $winNs } else { $linuxNs }
foreach ($ns in $namespaces) {
    try { kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f - } catch { Write-Warning ("Failed to ensure namespace {0}: {1}" -f $ns, $_.Exception.Message) }
}

# Optional: create regsecret in target namespaces if AcrUsername/AcrPassword provided
if ($AcrUsername -and $AcrPassword) {
    # Target namespaces (per-OS only; do not include the legacy top-level namespace)
    $targetNs = @($linuxNs, $winNs)

    # Build a well-formed dockerconfigjson and write to a temp file. Using --from-file with
    # a real .dockerconfigjson avoids kubectl/Helm validating errors about value contents.
    $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$AcrUsername`:$AcrPassword"))
    $dockerConfigObj = @{ auths = @{} }
    $dockerConfigObj.auths.Add("$AcrName.azurecr.io", @{ auth = $auth; username = $AcrUsername; password = $AcrPassword })
    $dockerConfigJson = ConvertTo-Json $dockerConfigObj -Depth 10
    # Compact JSON for the temp file as well
    $dockerConfigJson = ($dockerConfigJson -replace "\r?\n", "") -replace "\s+", " "
    $tmp = Join-Path $tmpDir "dockerconfig-$InstanceNumber.json"
    [System.IO.File]::WriteAllText($tmp, $dockerConfigJson)

    foreach ($ns in $targetNs) {
        Write-Host "Removing existing docker-registry secret 'regsecret' in namespace $ns' so Helm can create it"
        kubectl -n $ns delete secret regsecret --ignore-not-found
    }

    # Do NOT create the secret here; Helm will create it from the values block we injected above.
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# Render and deploy Helm chart
$releaseName = "az-selfhosted-agents-$InstanceNumber"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Find repository root by searching upwards for a folder that contains 'helm-charts-v2'
function Find-RepoRoot([string]$start) {
    try { $cur = (Resolve-Path $start).Path } catch { return $null }
    while ($cur) {
        if (Test-Path (Join-Path $cur 'helm-charts-v2')) { return $cur }
        $parent = Split-Path $cur -Parent
        if ($parent -eq $cur -or [string]::IsNullOrWhiteSpace($parent)) { break }
        $cur = $parent
    }
    return $null
}

$repoRoot = Find-RepoRoot $scriptRoot
if (-not $repoRoot) {
    Fail "Could not locate repository root containing 'helm-charts-v2'. Ensure you run this script from inside the repository or pass -Kubeconfig/-Acr params and adjust script location." 
}

$chartPath = Join-Path $repoRoot 'helm-charts-v2/az-selfhosted-agents'
if (-not (Test-Path $chartPath)) {
    Fail "Chart path $chartPath not found. Expected chart at: $chartPath. Verify the repository contains 'helm-charts-v2/az-selfhosted-agents'."
}

Write-Host "Rendering chart templates and installing release $releaseName to namespace $releaseNamespace"
# Ensure any stale regsecret is removed before Helm attempts to create/patch it.
try { & kubectl -n $releaseNamespace delete secret regsecret --ignore-not-found } catch { Write-Host "Warning: failed to delete existing regsecret in $releaseNamespace (non-fatal)" }
helm dependency update $chartPath | Out-Null

# Run helm with --atomic and --debug, saving output to a temp log. --atomic will rollback on failure.
$helmLog = Join-Path $tmpDir "helm-install-$releaseName-$InstanceNumber.log"
$helmArgs = @('upgrade', '--install', $releaseName, $chartPath, '--namespace', $releaseNamespace, '--create-namespace', '-f', $yamlPath, '--wait', '--timeout', $HelmTimeout, '--atomic', '--debug')
Write-Host "Running helm with args: $($helmArgs -join ' ')"
# Run helm and tee output to both console and a temp log file while capturing output
# Avoid using Tee-Object's -Variable parameter here (it conflicts when also
# assigning the pipeline result to a variable). Capture the pipeline output
# into $helmOutput and write to the log file via Tee-Object -FilePath.
$helmOutput = & helm @helmArgs 2>&1 | Tee-Object -FilePath $helmLog
$hc = $LASTEXITCODE
if ($hc -eq 0) {
    Write-Host "Helm release $releaseName deployed to namespace $releaseNamespace"
    # Print a masked copy of helm output to avoid leaking secrets
    try {
        $rawHelm = ($helmOutput -join "`n")
        Write-Host '--- HELM OUTPUT (masked) ---'
        Write-Host (Mask-SensitiveYaml $rawHelm)
        Write-Host '--- end HELM OUTPUT ---'
    }
    catch { }
}
else {
    Write-Warning "Helm deployment reported an error: exit code $hc"

    # Print helm log if present
    if (Test-Path $helmLog) {
        Write-Host "--- HELM INSTALL LOG: $helmLog ---"
        $raw = Get-Content -Path $helmLog -Raw -ErrorAction SilentlyContinue
        if ($raw) { Write-Host (Mask-SensitiveYaml $raw) } else { Get-Content -Path $helmLog -Tail 200 | ForEach-Object { Write-Host $_ } }
        Write-Host "--- end HELM INSTALL LOG ---"
    }

    # Dump recent events from the release namespace to help triage
    try {
        Write-Host "--- recent events in namespace $releaseNamespace ---"
        kubectl get events -n $releaseNamespace --sort-by=.metadata.creationTimestamp | Select-Object -Last 100 | ForEach-Object { Write-Host $_ }
        Write-Host "--- end events ---"
    }
    catch { Write-Warning ([string]::Format('Failed to fetch events: {0}', $_.Exception.Message)) }

    # Print masked helm values and manifest if available
    try {
        $hv = & helm get values $releaseName -n $releaseNamespace --all 2>$null | Out-String
        if ($hv) { Write-Host '--- helm get values (masked) ---'; Write-Host (Mask-SensitiveYaml $hv); Write-Host '--- end helm values ---' }
    }
    catch { }
    try {
        $hm = & helm get manifest $releaseName -n $releaseNamespace 2>$null | Out-String
        if ($hm) { Write-Host '--- helm manifest (masked) ---'; Write-Host (Mask-SensitiveYaml $hm); Write-Host '--- end manifest ---' }
    }
    catch { }
}
# Post-deploy verification: print applied helm values and confirm poolID entries are non-empty
Write-Host "Post-deploy: verifying applied Helm values for release $releaseName in namespace $releaseNamespace"

# Safely attempt to read applied values. Use a guarded single-line try/catch to avoid parser fragility.
$appliedValues = $null
try { $appliedValues = & helm get values $releaseName -n $releaseNamespace --all 2>$null | Out-String } catch { $appliedValues = $null }

Write-Host '--- helm get values (applied, masked) ---'
if ($appliedValues) { Write-Host (Mask-SensitiveYaml $appliedValues) } else { Write-Warning "Could not retrieve applied helm values for ${releaseName} in namespace ${releaseNamespace}." }
Write-Host '--- end helm values ---'

# If we have values, extract pool IDs; otherwise skip extraction.
if ($appliedValues) {
    # Extract poolID.linux and poolID.windows using regex (handles quoted or unquoted values)
    $linuxPoolID = ''
    $windowsPoolID = ''
    $patternLinux = @'
poolID:\s*\n\s*linux:\s*(?:"|')?([^"'\r\n]+)(?:"|')?
'@
    $mLinux = [regex]::Match($appliedValues, $patternLinux)
    if ($mLinux.Success) { $linuxPoolID = $mLinux.Groups[1].Value }

    $patternWindows = @'
poolID:\s*\n[\s\S]*?windows:\s*(?:"|')?([^"'\r\n]+)(?:"|')?
'@
    $mWindows = [regex]::Match($appliedValues, $patternWindows)
    if ($mWindows.Success) { $windowsPoolID = $mWindows.Groups[1].Value }

    if (-not $linuxPoolID -or $linuxPoolID -eq 'x') {
        Write-Warning "poolID.linux appears unset or still placeholder ('$linuxPoolID'). KEDA ScaledObject may fail to parse poolID."
    }
    else {
        Write-Host "Resolved poolID.linux = $linuxPoolID"
    }
    if (-not $windowsPoolID -or $windowsPoolID -eq 'y') {
        Write-Warning "poolID.windows appears unset or still placeholder ('$windowsPoolID'). KEDA ScaledObject may fail to parse poolID."
    }
    else {
        Write-Host "Resolved poolID.windows = $windowsPoolID"
    }
}
else {
    Write-Warning "Skipping poolID extraction because helm get values returned no data for ${releaseName} in ${releaseNamespace}."
}

# Post-deploy: list pods and deployments in release namespace (guard against empty namespace)
Write-Host "Post-deploy: list pods and deployments in release namespace $releaseNamespace"
if ([string]::IsNullOrWhiteSpace($releaseNamespace)) {
    Write-Warning 'Release namespace is empty; skipping kubectl listing.'
}
else {
    try {
        kubectl get pods -n $releaseNamespace -o wide
    }
    catch {
        Write-Warning ([string]::Format('Failed to list pods in {0}: {1}', $releaseNamespace, $_.Exception.Message))
    }

    try {
        kubectl get deployment -n $releaseNamespace -o wide
    }
    catch {
        Write-Warning ([string]::Format('Failed to list deployments in {0}: {1}', $releaseNamespace, $_.Exception.Message))
    }
}

Write-Host "Done. If any pods are ImagePullBackOff/ErrImagePull, ensure a docker-registry secret named 'regsecret' exists in the pod namespace and points to $AcrName.azurecr.io"
