<#
.azuredevops/scripts/uninstall-selfhosted-agents-helm.ps1

Idempotent cleanup for local/dev clusters that were provisioned with
deploy-selfhosted-agents-helm.ps1.

This script will:
- helm uninstall the release created by the deploy script
- delete the namespaces created (az-devops-<N>, az-devops-linux-<N>, az-devops-windows-<N>)
- remove a docker-registry secret named `regsecret` from those namespaces
- uninstall KEDA (helm release `keda`) and delete the `keda` namespace
- optionally delete KEDA CRDs (default: true)

The script is designed to be safe and idempotent: missing resources are ignored
and Terminating namespaces can be forcibly cleared of finalizers if necessary.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $InstanceNumber, #'003'
    [Parameter(Mandatory = $false)] [string] $Kubeconfig = "aks-ado-agents-$InstanceNumber",
    [Parameter(Mandatory = $false)] [string] $KubeconfigAzureLocal, #"my-workload-cluster-dev-014-kubeconfig.yaml"
    [Parameter(Mandatory = $false)] [string] $KubeconfigFolder,        
    [Parameter(Mandatory = $false)] [string] $KubeContext = "aks-ado-agents-$InstanceNumber",
    [Parameter(Mandatory = $false)] [string] $KubeContextAzureLocal, #"my-workload-cluster-dev-014-admin@my-workload-cluster-dev-014"
    [Parameter(Mandatory = $false)] [switch] $UseAzureLocal,
    [Parameter(Mandatory = $false)] [string] $AksResourceGroup = "rg-aks-ado-agents-$InstanceNumber",
    [Parameter(Mandatory = $false)] [string] $AksClusterName = "aks-ado-agents-$InstanceNumber",
    # Use booleans so we can have sensible defaults (true) while remaining easy to call
    [Parameter(Mandatory = $false)] [bool] $RemoveKeda = $true,
    [Parameter(Mandatory = $false)] [bool] $RemoveKedaCRDs = $true,
    [Parameter(Mandatory = $false)] [bool] $RemoveNamespaces = $true,
    [Parameter(Mandatory = $false)] [bool] $RemoveSecrets = $true,
    [Parameter(Mandatory = $false)] [bool] $ForceFinalize = $true,
    [Parameter(Mandatory = $false)] [string] $AzDevOpsUrl,
    # Backwards-compatible alias used by pipeline templates
    [Parameter(Mandatory = $true)] [string] $AzureDevOpsOrgUrl, #"https://dev.azure.com/cad4devops"
    [Parameter(Mandatory = $false)] [string] $AzDevOpsToken,
    [Parameter(Mandatory = $false)] [bool] $RemoveAzDoPools = $true,
    # Pipeline-compatible flags (some pipelines pass these names)
    [Parameter(Mandatory = $false)] [object] $RemoveLinux = $true,
    [Parameter(Mandatory = $false)] [object] $RemoveWindows = $true,
    [Parameter(Mandatory = $false)] [object] $DeleteAgentPools = $true,
    [Parameter(Mandatory = $false)] [string] $ConfirmDeletion = 'YES',
    # Accept object here and coerce to bool so callers can pass 'true'/'false' strings without binding errors
    [Parameter(Mandatory = $false)] [object] $VerboseHttp = $false
)

function ConvertTo-Bool([object]$v) {
    if ($v -is [bool]) { return $v }
    if ($null -eq $v) { return $false }
    try {
        $s = $v.ToString().Trim().ToLowerInvariant()
    }
    catch { return $false }
    switch ($s) {
        '1' { return $true }
        '0' { return $false }
        'true' { return $true }
        'false' { return $false }
        'yes' { return $true }
        'no' { return $false }
        'y' { return $true }
        'n' { return $false }
        default { return $false }
    }
}

# Coerce VerboseHttp early so the rest of the script can rely on a boolean
$VerboseHttp = ConvertTo-Bool $VerboseHttp

# Coerce pipeline-friendly flags to booleans
$RemoveLinux = ConvertTo-Bool $RemoveLinux
$RemoveWindows = ConvertTo-Bool $RemoveWindows
$DeleteAgentPools = ConvertTo-Bool $DeleteAgentPools

# Map pipeline DeleteAgentPools to internal RemoveAzDoPools when provided
if ($PSBoundParameters.ContainsKey('DeleteAgentPools')) {
    $RemoveAzDoPools = $DeleteAgentPools
}

# Ensure ConfirmDeletion is respected if provided (pipeline already validates it)
if ($PSBoundParameters.ContainsKey('ConfirmDeletion')) {
    if (($ConfirmDeletion -ne 'YES') -and ($ConfirmDeletion -ne 'Yes')) {
        Fail "ConfirmDeletion must be 'YES' to proceed. Current: '$ConfirmDeletion'"
    }
}

function Fail([string]$msg) { Write-Error $msg; exit 1 }

Write-Host "Starting uninstall script (instance=$InstanceNumber)"

# Cross-platform green output helper:
# - On Windows use Write-Host -ForegroundColor (PowerShell host supports it)
# - On non-Windows or CI agents, emit ANSI green escape sequences so Azure Pipelines
#   and other terminals that support ANSI colors render the message in green.
function Write-Green([string]$msg) {
    try {
        if ($IsWindows) {
            Write-Host -ForegroundColor Green $msg
        }
        else {
            # Use ANSI SGR codes: 32 = green, 0 = reset
            Write-Host "`e[32m$msg`e[0m"
        }
    }
    catch {
        # Fallback to plain text if something unexpected happens
        Write-Host $msg
    }
}

# If running in Azure-local/on-prem mode require certain params to be provided so uninstall targets the correct cluster and pools
if ($UseAzureLocal.IsPresent) {
    $missing = @()
    if (-not $KubeconfigAzureLocal -or [string]::IsNullOrWhiteSpace($KubeconfigAzureLocal)) { $missing += 'KubeconfigAzureLocal' }
    if (-not $KubeContextAzureLocal -or [string]::IsNullOrWhiteSpace($KubeContextAzureLocal)) { $missing += 'KubeContextAzureLocal' }
    if ($missing.Count -gt 0) {
        Fail ("When -UseAzureLocal is set the following parameters must be provided and non-empty: {0}" -f ($missing -join ', '))
    }
}

# Support legacy and new parameter names: normalize to canonical $AzureDevOpsOrgUrl
if ($AzDevOpsUrl -and -not $AzureDevOpsOrgUrl) { $AzureDevOpsOrgUrl = $AzDevOpsUrl }
if ($AzureDevOpsOrgUrl -and -not $AzDevOpsUrl) { $AzDevOpsUrl = $AzureDevOpsOrgUrl }

# kubeconfig handling: az-first unless -UseAzureLocal is set. This prefers fetching AKS
# credentials when running against cloud clusters but will fall back to an existing
# KUBECONFIG or local kubeconfig files when az is unavailable or fails.
# Resolve effective kubeconfig folder when using local kubeconfig. Default to C:\Users\<user>\.kube
$userProfile = $env:USERPROFILE; if (-not $userProfile) { $userProfile = $env:HOME }
if ($KubeconfigFolder) { $effectiveKubeFolder = $KubeconfigFolder } elseif ($userProfile) { $effectiveKubeFolder = Join-Path $userProfile '.kube' } else { $effectiveKubeFolder = Join-Path ([System.IO.Path]::GetTempPath()) '.kube' }

# Decide which input parameter to honour for kubeconfig based on UseAzureLocal
$effectiveKubeParamName = if ($UseAzureLocal.IsPresent) { 'KubeconfigAzureLocal' } else { 'Kubeconfig' }
$effectiveKubeParam = if ($UseAzureLocal.IsPresent) { $KubeconfigAzureLocal } else { $Kubeconfig }

Write-Host "DEBUG: UseAzureLocal.IsPresent=$($UseAzureLocal.IsPresent); selected param=$effectiveKubeParamName; value='$effectiveKubeParam'"

if (-not $UseAzureLocal.IsPresent) {
    # Non-local: prefer a provided kubeconfig file (pipeline may pass a KUBECONFIG path). If none provided or file missing, fetch via az.
    $provided = $effectiveKubeParam
    $usedProvided = $false
    if ($provided) {
        try {
            $isAbs = [System.IO.Path]::IsPathRooted($provided)
        }
        catch { $isAbs = $false }
        if ($isAbs -and (Test-Path $provided)) {
            $env:KUBECONFIG = (Resolve-Path $provided).Path
            $usedProvided = $true
            Write-Host "Using provided kubeconfig file (absolute): $env:KUBECONFIG"
        }
        elseif (-not $isAbs) {
            # Try resolving relative to effective folder
            $candidate = Join-Path $effectiveKubeFolder $provided
            if (Test-Path $candidate) {
                $env:KUBECONFIG = (Resolve-Path $candidate).Path
                $usedProvided = $true
                Write-Host "Using provided kubeconfig file (relative resolved): $env:KUBECONFIG"
            }
        }
    }

    if (-not $usedProvided) {
        Write-Host 'No usable provided kubeconfig found; fetching AKS credentials via az CLI.'
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) { Fail "Azure CLI (az) not found in PATH. Install Azure CLI or run with -UseAzureLocal and provide a local kubeconfig." }
        if (-not $AksResourceGroup -or -not $AksClusterName) { Fail "To fetch AKS credentials the script requires -AksResourceGroup and -AksClusterName when -UseAzureLocal is not set and no kubeconfig was provided." }
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
}
else {
    # Local mode: prefer KubeconfigAzureLocal (explicit local kubeconfig filename), then fall back to Kubeconfig if provided, else legacy locations
    $localCandidate = $null
    if ($effectiveKubeParam) {
        try { $isAbs = [System.IO.Path]::IsPathRooted($effectiveKubeParam) } catch { $isAbs = $false }
        if ($isAbs) { $localCandidate = $effectiveKubeParam }
        else { $localCandidate = Join-Path $effectiveKubeFolder $effectiveKubeParam }
    }
    else {
        $localCandidate = Join-Path $effectiveKubeFolder 'config\my-workload-cluster-dev-014-kubeconfig.yaml'
    }

    if (Test-Path $localCandidate) {
        $env:KUBECONFIG = (Resolve-Path $localCandidate).Path
        Write-Host "Using local kubeconfig: $env:KUBECONFIG"
    }
    else {
        $legacy = Join-Path $effectiveKubeFolder 'config'
        if (Test-Path $legacy) {
            $env:KUBECONFIG = (Resolve-Path $legacy).Path
            Write-Host "Using legacy kubeconfig at $env:KUBECONFIG"
        }
        else {
            Write-Warning "Local kubeconfig not found at $localCandidate or $legacy; will attempt to use default kubectl context."
        }
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
        # Use jsonpath to reliably list context names; coerce to a single string then split on whitespace
        $ctxRaw = (& kubectl --kubeconfig $env:KUBECONFIG config view -o jsonpath="{.contexts[*].name}" 2>$null) -join ' '
        $ctxs = @()
        if ($ctxRaw) { $ctxs = ($ctxRaw -split '\s+') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } }
        if ($ctxs.Count -gt 0) {
            $firstCtx = $ctxs[0]
            try { & kubectl --kubeconfig $env:KUBECONFIG config use-context $firstCtx > $null 2>&1; Write-Host "Set kubectl current-context to $firstCtx (from $env:KUBECONFIG)" }
            catch { Write-Warning "Failed to set kubectl current-context to $firstCtx" }
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

# Verify we can reach the cluster early; warn if not (uninstall is tolerant)
try {
    Write-Host 'Verifying cluster access with: kubectl get nodes -o wide'
    kubectl get nodes -o wide | Out-Null
    Write-Host 'Cluster access verified.'
}
catch {
    Write-Warning "Failed to list nodes from cluster (kubectl get nodes -o wide). Uninstall will continue but may not target the intended cluster. Error: $($_.Exception.Message)"
}

# If caller provided expected contexts, check and warn/fail appropriately.
try {
    if ($UseAzureLocal.IsPresent -and $KubeContextAzureLocal) { $expectedCtx = $KubeContextAzureLocal }
    elseif ($KubeContext) { $expectedCtx = $KubeContext }
    else { $expectedCtx = $null }

    if ($expectedCtx) {
        $current = (& kubectl config current-context 2>$null) -as [string]
        if (-not $current) {
            if (-not $UseAzureLocal.IsPresent) { Fail "No current kubectl context detected but expected '$expectedCtx'. Ensure AKS credentials were fetched correctly." }
            else { Write-Warning "No current kubectl context detected but expected '$expectedCtx'. Uninstall will continue." }
        }
        elseif ($current.Trim() -ne $expectedCtx.Trim()) {
            if (-not $UseAzureLocal.IsPresent) { Fail "Current kubectl context '$current' does not match expected context '$expectedCtx'. Aborting." }
            else { Write-Warning "Current kubectl context '$current' does not match expected context '$expectedCtx'. Uninstall will continue but may not target intended cluster." }
        }
        else { Write-Green "Current kubectl context '$current' matches expected context '$expectedCtx'." }
    }
}
catch {
    Write-Warning "Error while validating current kubectl context: $($_.Exception.Message)" 
}

# Determine effective Azure DevOps PAT (prefer parameter, fall back to AZDO_PAT env var)
$effectiveAzDoToken = $AzDevOpsToken
if (-not $effectiveAzDoToken -and $env:AZDO_PAT) {
    $effectiveAzDoToken = $env:AZDO_PAT
    Write-Host "Using Azure DevOps PAT from AZDO_PAT environment variable"
}

# If the caller requested Azure DevOps pool removal, require both org URL and PAT early and fail fast to avoid partial uninstall.
if ($RemoveAzDoPools) {
    if (-not $AzureDevOpsOrgUrl) {
        Write-Warning "RemoveAzDoPools requested but AzureDevOpsOrgUrl not provided; skipping pool removal. Provide -AzureDevOpsOrgUrl to enable pool removal."
        $RemoveAzDoPools = $false
    }
    if ($RemoveAzDoPools -and -not $effectiveAzDoToken) {
        Write-Warning "RemoveAzDoPools requested but no Azure DevOps PAT supplied (AzDevOpsToken param or AZDO_PAT env var); skipping pool removal."
        $RemoveAzDoPools = $false
    }
}

function Exec([string]$cmd) {
    Write-Host "> $cmd"
    try {
        Invoke-Expression $cmd
    }
    catch {
        Write-Warning ("Command failed: {0} -- {1}" -f $cmd, $_.Exception.Message)
    }
}

function Remove-HelmRelease([string]$release, [string]$namespace) {
    if (-not $release) { return }
    Write-Host "Uninstalling Helm release '$release' in namespace '$namespace' (if present)"
    try {
        helm uninstall $release --namespace $namespace --wait --timeout 5m 2>&1 | Out-Null
        Write-Host "Requested uninstall of release $release"
    }
    catch {
        Write-Warning ("helm uninstall reported an issue: {0}" -f $_.Exception.Message)
    }
}

function Remove-NS([string]$ns) {
    if (-not $ns) { return }
    Write-Host "Deleting namespace '$ns' (if present)"
    try {
        kubectl delete namespace $ns --ignore-not-found --wait --timeout=5m 2>$null | Out-Null
    }
    catch {
        Write-Warning ("kubectl delete namespace {0} returned error: {1}" -f $ns, $_.Exception.Message)
    }

    # If namespace still exists and is Terminating, optionally clear finalizers
    try {
        $nsJson = kubectl get namespace $ns -o json 2>$null
        if ($nsJson) {
            $j = $nsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($j -and $j.status -and $j.status.phase -eq 'Terminating') {
                if ($ForceFinalize) {
                    Write-Host "Namespace $ns is Terminating; removing finalizers to force deletion"
                    # Patch finalizers to empty array
                    kubectl patch namespace $ns -p '{"metadata":{"finalizers":[]}}' --type=merge 2>&1 | Out-Null
                    Write-Host "Patched finalizers on $ns; attempting delete again"
                    kubectl delete namespace $ns --ignore-not-found --wait --timeout=2m 2>$null | Out-Null
                }
                else {
                    Write-Warning "Namespace $ns is Terminating and ForceFinalize is not set; leaving as-is"
                }
            }
        }
    }
    catch {
        Write-Warning ("Failed to inspect/patch namespace {0}: {1}" -f $ns, $_.Exception.Message)
    }
}

# Compose target names
$baseNs = "az-devops-$InstanceNumber" # legacy/compat namespace (may be absent)
$linuxNs = "az-devops-linux-$InstanceNumber"
$winNs = "az-devops-windows-$InstanceNumber"
$releaseName = "az-selfhosted-agents-$InstanceNumber"

# Azure DevOps pool names created by the deploy script
$azPoolLinux = if ($UseAzureLocal.IsPresent) { "KubernetesPoolOnPremLinux$InstanceNumber" } else { "KubernetesPoolLinux$InstanceNumber" }
$azPoolWindows = if ($UseAzureLocal.IsPresent) { "KubernetesPoolOnPremWindows$InstanceNumber" } else { "KubernetesPoolWindows$InstanceNumber" }

function Remove-Pool([string]$orgUrl, [string]$pat, [string]$poolName) {
    if (-not ($orgUrl -and $pat -and $poolName)) { return }
    Write-Host "Looking for Azure DevOps pool '$poolName' at $orgUrl"
    $authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $pat))
    # Ask for JSON and provide a User-Agent so the service returns JSON rather than HTML sign-in pages
    $headers = @{
        Authorization  = $authHeader
        Accept         = 'application/json'
        'Content-Type' = 'application/json'
        'User-Agent'   = 'uninstall-selfhosted-agents-ps'
    }

    # Try agent pools endpoint first, then fallback to deployment pools (some pools are created via deployment API)
    $apiVersions = @('7.1-preview.1', '6.0-preview.1', '5.1-preview.1')
    $found = $false
    function Get-ResponseBodyAndStatus($respObj) {
        try {
            if ($null -eq $respObj) { return @{ Status = $null; Body = $null } }
            # System.Net.WebException.Response -> WebResponse with GetResponseStream
            if ($respObj -is [System.Net.WebResponse]) {
                $status = $respObj.StatusCode 2>$null
                try { $body = (New-Object System.IO.StreamReader($respObj.GetResponseStream())).ReadToEnd() } catch { $body = $null }
                return @{ Status = $status; Body = $body }
            }
            # PowerShell Core often exposes HttpResponseMessage
            if ($respObj -is [System.Net.Http.HttpResponseMessage]) {
                $status = $respObj.StatusCode
                $body = $respObj.Content.ReadAsStringAsync().Result
                return @{ Status = $status; Body = $body }
            }
            # Fallback: try properties
            if ($respObj.StatusCode -or $respObj.Content) {
                $status = $respObj.StatusCode 2>$null
                try { $body = $respObj.Content.ReadAsStringAsync().Result } catch { $body = $null }
                return @{ Status = $status; Body = $body }
            }
        }
        catch { }
        return @{ Status = $null; Body = $null }
    }

    foreach ($apiVersion in $apiVersions) {
        $getUri = "$orgUrl/_apis/distributedtask/pools?poolName=$([Uri]::EscapeDataString($poolName))&api-version=$apiVersion"
        try {
            if ($VerboseHttp) { Write-Host "HTTP GET $getUri" }
            $resp = Invoke-RestMethod -Method Get -Uri $getUri -Headers $headers -ErrorAction Stop
            if ($VerboseHttp) { Write-Host "HTTP GET returned:"; $resp | ConvertTo-Json -Depth 5 | Write-Host }
            if ($resp.count -gt 0 -and $resp.value[0].id) {
                $id = $resp.value[0].id
                Write-Host "Found agent pool $poolName id=$id (api-version=$apiVersion); attempting delete via distributedtask/pools"
                foreach ($delVer in $apiVersions) {
                    # Use $($id) to avoid parser ambiguity when variable is adjacent to '?'
                    $delUri = "$orgUrl/_apis/distributedtask/pools/$($id)?api-version=$delVer"
                    try {
                        if ($VerboseHttp) { Write-Host "HTTP DELETE $delUri" }
                        $delResp = Invoke-WebRequest -Method Delete -Uri $delUri -Headers $headers -ErrorAction Stop
                        if ($VerboseHttp) { Write-Host "HTTP DELETE returned status: $($delResp.StatusCode)" }
                        Write-Host "Deleted agent pool $poolName (id=$id) using api-version=$delVer"
                        $found = $true
                        break
                    }
                    catch {
                        $lastErr = $_
                        if ($_.Exception -and $_.Exception.Response -and $VerboseHttp) {
                            try {
                                $info = Get-ResponseBodyAndStatus $_.Exception.Response
                                Write-Warning ("HTTP DELETE failed for {0}: Status={1}" -f $delUri, $info.Status)
                                if ($info.Body) { Write-Host "Response body:"; Write-Host $info.Body }
                            }
                            catch { }
                        }
                    }
                }
                if (-not $found) {
                    Write-Warning ("Failed to delete agent pool {0}: {1}" -f $poolName, $lastErr.Exception.Message)
                    Write-Warning "Hint: ensure the PAT has 'Agent Pools (read & manage)' scope and your account is a Collection Administrator."
                }
                break
            }
        }
        catch {
            # Try to surface HTTP status and body when available (helps explain HTML sign-in pages / 401s)
            if ($_.Exception -and $_.Exception.Response) {
                try {
                    $info = Get-ResponseBodyAndStatus $_.Exception.Response
                    if ($VerboseHttp) { Write-Warning ("HTTP GET failed for {0}: {1} - Status: {2}" -f $getUri, $_.Exception.Message, $info.Status) }
                    if ($VerboseHttp -and $info.Body) { Write-Host "Response body:"; Write-Host $info.Body }
                }
                catch {
                    if ($VerboseHttp) { Write-Warning ("HTTP GET failed for {0}: {1} (failed to read response body)" -f $getUri, $_.Exception.Message) }
                }
            }
            else {
                if ($VerboseHttp) { Write-Warning ("HTTP GET failed for {0}: {1}" -f $getUri, $_.Exception.Message) }
            }
            # ignore and continue, we'll try deploymentpools next
        }
    }

    if (-not $found) {
        # Try deployment pools endpoint as a fallback
        foreach ($apiVersion in $apiVersions) {
            $getUri2 = "$orgUrl/_apis/distributedtask/deploymentpools?poolName=$([Uri]::EscapeDataString($poolName))&api-version=$apiVersion"
            try {
                if ($VerboseHttp) { Write-Host "HTTP GET $getUri2" }
                $resp2 = Invoke-RestMethod -Method Get -Uri $getUri2 -Headers $headers -ErrorAction Stop
                if ($VerboseHttp) { Write-Host "HTTP GET returned:"; $resp2 | ConvertTo-Json -Depth 5 | Write-Host }
                if ($resp2.count -gt 0 -and $resp2.value[0].id) {
                    $id2 = $resp2.value[0].id
                    Write-Host "Found deployment pool $poolName id=$id2 (api-version=$apiVersion); attempting delete via distributedtask/deploymentpools"
                    foreach ($delVer in $apiVersions) {
                        $delUri2 = "$orgUrl/_apis/distributedtask/deploymentpools/$($id2)?api-version=$delVer"
                        try {
                            if ($VerboseHttp) { Write-Host "HTTP DELETE $delUri2" }
                            $delResp2 = Invoke-WebRequest -Method Delete -Uri $delUri2 -Headers $headers -ErrorAction Stop
                            if ($VerboseHttp) { Write-Host "HTTP DELETE returned status: $($delResp2.StatusCode)" }
                            Write-Host "Deleted deployment pool $poolName (id=$id2) using api-version=$delVer"
                            $found = $true
                            break
                        }
                        catch {
                            $lastErr = $_
                            if ($_.Exception -and $_.Exception.Response -and $VerboseHttp) {
                                try {
                                    $info = Get-ResponseBodyAndStatus $_.Exception.Response
                                    Write-Warning ("HTTP DELETE failed for {0}: Status={1}" -f $delUri2, $info.Status)
                                    if ($info.Body) { Write-Host "Response body:"; Write-Host $info.Body }
                                }
                                catch { }
                            }
                        }
                    }
                    if (-not $found) {
                        Write-Warning ("Failed to delete deployment pool {0}: {1}" -f $poolName, $lastErr.Exception.Message)
                        Write-Warning "Hint: ensure the PAT has 'Deployment pools (read & manage)' scope or equivalent permissions."
                    }
                    break
                }
            }
            catch {
                if ($VerboseHttp) {
                    if ($_.Exception -and $_.Exception.Response) {
                        try {
                            $info = Get-ResponseBodyAndStatus $_.Exception.Response
                            Write-Warning ("HTTP GET failed for {0}: {1} - Status: {2}" -f $getUri2, $_.Exception.Message, $info.Status)
                            if ($info.Body) { Write-Host "Response body:"; Write-Host $info.Body }
                        }
                        catch {
                            Write-Warning ("HTTP GET failed for {0}: {1} (failed to read response body)" -f $getUri2, $_.Exception.Message)
                        }
                    }
                    else {
                        Write-Warning ("HTTP GET failed for {0}: {1}" -f $getUri2, $_.Exception.Message)
                    }
                }
                # ignore and continue
            }
        }
    }

    if (-not $found) { Write-Host "Pool $poolName not found or not deletable via API; you can delete it from Organization settings -> Agent pools in the web UI." }
}

# 1) Uninstall the main Helm release
# Prefer uninstalling from linux namespace if present, else windows, else legacy base namespace
$releaseNsFound = $null
try {
    $out = kubectl get ns $linuxNs -o json 2>$null | Out-String
    if ($out -and $out.Trim().Length -gt 0) { $releaseNsFound = $linuxNs }
}
catch { }
if (-not $releaseNsFound) {
    try { $out = kubectl get ns $winNs -o json 2>$null | Out-String ; if ($out -and $out.Trim().Length -gt 0) { $releaseNsFound = $winNs } } catch { }
}
if (-not $releaseNsFound) {
    try { $out = kubectl get ns $baseNs -o json 2>$null | Out-String ; if ($out -and $out.Trim().Length -gt 0) { $releaseNsFound = $baseNs } } catch { }
}
if ($releaseNsFound) {
    Remove-HelmRelease -release $releaseName -namespace $releaseNsFound
}
else {
    Write-Warning "No candidate namespace found for Helm release $releaseName; attempting uninstall in legacy namespace $baseNs"
    Remove-HelmRelease -release $releaseName -namespace $baseNs
}

# Optionally remove Azure DevOps pools
if ($RemoveAzDoPools) {
    $pat = $AzDevOpsToken; if (-not $pat) { $pat = $env:AZDO_PAT }
    if (-not $pat) { Write-Warning 'AZDO_PAT / AzDevOpsToken not provided; skipping AzDevOps pool removal' } else {
        if (-not $AzureDevOpsOrgUrl) { Write-Warning 'AzureDevOpsOrgUrl not provided; skipping pool removal' } else {
            Remove-Pool -orgUrl $AzureDevOpsOrgUrl -pat $pat -poolName $azPoolLinux
            Remove-Pool -orgUrl $AzureDevOpsOrgUrl -pat $pat -poolName $azPoolWindows
        }
    }
}

# 2) Optionally remove regsecret and azdevops secret from target namespaces
if ($RemoveSecrets) {
    # Legacy/base namespace
    try { Write-Host "Removing 'regsecret' and 'azdevops' secrets in namespace $baseNs (ignore if missing)"; kubectl -n $baseNs delete secret regsecret --ignore-not-found 2>$null | Out-Null } catch { }
    try { kubectl -n $baseNs delete secret azdevops --ignore-not-found 2>$null | Out-Null } catch { }

    if ($RemoveLinux) {
        try { Write-Host "Removing 'regsecret' and 'azdevops' secrets in namespace $linuxNs (ignore if missing)"; kubectl -n $linuxNs delete secret regsecret --ignore-not-found 2>$null | Out-Null } catch { }
        try { kubectl -n $linuxNs delete secret azdevops --ignore-not-found 2>$null | Out-Null } catch { }
    }

    if ($RemoveWindows) {
        try { Write-Host "Removing 'regsecret' and 'azdevops' secrets in namespace $winNs (ignore if missing)"; kubectl -n $winNs delete secret regsecret --ignore-not-found 2>$null | Out-Null } catch { }
        try { kubectl -n $winNs delete secret azdevops --ignore-not-found 2>$null | Out-Null } catch { }
    }
}

# 3) Uninstall KEDA (default behavior)
if ($RemoveKeda) {
    Write-Host "Uninstalling KEDA (helm release 'keda' in namespace 'keda')"
    Remove-HelmRelease -release 'keda' -namespace 'keda'
    # delete the keda namespace
    if ($RemoveNamespaces) {
        Remove-NS -ns 'keda'
    }
    if ($RemoveKedaCRDs) {
        Write-Host "Removing KEDA CRDs (if present)"
        $crds = @('scaledobjects.keda.sh', 'scaledjobs.keda.sh', 'triggerauthentications.keda.sh', 'clustertriggerauthentications.keda.sh')
        foreach ($c in $crds) {
            try { kubectl delete crd $c --ignore-not-found 2>$null | Out-Null } catch { Write-Warning ("Failed to delete CRD {0}: {1}" -f $c, $_.Exception.Message) }
        }
    }
}

# 4) Remove the agent namespaces
if ($RemoveNamespaces) {
    # Remove per-OS namespaces according to flags; also attempt legacy base namespace if present
    if ($RemoveLinux) { Remove-NS -ns $linuxNs }
    if ($RemoveWindows) { Remove-NS -ns $winNs }
    # Always attempt legacy base namespace removal when RemoveNamespaces is true
    Remove-NS -ns $baseNs
}

# 5) Final cleanup: list remaining resources for user's inspection
Write-Host "Cleanup requested completed. Current Helm releases:"
try { helm list -A } catch { Write-Warning "helm list failed" }

Write-Host "Remaining namespaces (filtered by az-devops* and keda):"
try { kubectl get namespaces -o wide --no-headers | Where-Object { $_ -match 'az-devops|keda' } | ForEach-Object { Write-Host $_ } } catch { Write-Warning "kubectl get namespaces failed" }

Write-Host "If any namespace remains in Terminating state you can re-run this script with -ForceFinalize to remove finalizers and force deletion."
Write-Host "Done."
