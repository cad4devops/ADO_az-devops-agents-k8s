<#
.azuredevops/scripts/deploy-selfhosted-agents-helm.ps1

This script performs the same high-level steps as the pipeline
`deploy-selfhosted-agents-helm.yml` so you can run it locally for
development and debugging.

Usage (example):
  pwsh ./.azuredevops/scripts/deploy-selfhosted-agents-helm.ps1 \
    -Kubeconfig C:\path\to\kubeconfig \
    -InstanceNumber 003 \
    -AcrName cragentssgvhe4aipy37o \
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
    [Parameter(Mandatory=$false)] [string] $Kubeconfig,
    [Parameter(Mandatory=$false)] [switch] $DeployLinux = $true,
    [Parameter(Mandatory=$false)] [switch] $DeployWindows = $true,
    [Parameter(Mandatory=$false)] [string] $WindowsVersion = '2022',
    [Parameter(Mandatory=$false)] [ValidateSet('docker','dind','ubuntu22')] [string] $LinuxImageVariant = 'docker',
    [Parameter(Mandatory=$false)] [string] $AcrName = 'cragentssgvhe4aipy37o',
    [Parameter(Mandatory=$false)] [string] $AzureDevOpsOrgUrl = 'https://dev.azure.com/cad4devops',
    [Parameter(Mandatory=$false)] [string] $InstanceNumber = '003',
    [Parameter(Mandatory=$false)] [string] $BootstrapPoolName = 'KubernetesPoolWindows',
    [Parameter(Mandatory=$false)] [string] $AcrUsername,
    [Parameter(Mandatory=$false)] [string] $AcrPassword,
    # NOTE: we accept only AzureDevOpsOrgUrl now (legacy alias removed)
    [Parameter(Mandatory=$false)] [string] $AzDevOpsToken,
    [Parameter(Mandatory=$false)] [string] $AzDevOpsPool,
    [Parameter(Mandatory=$false)] [string] $AzDevOpsPoolLinux,
    [Parameter(Mandatory=$false)] [string] $AzDevOpsPoolWindows,
    [Parameter(Mandatory=$false)] [switch] $WriteValuesOnly,
    [Parameter(Mandatory=$false)] [switch] $EnsureAzDoPools
)



function Fail([string]$msg){ Write-Error $msg; exit 1 }

Write-Host "Starting local deploy script (instance=$InstanceNumber)"

# kubeconfig handling
if($Kubeconfig){
    if(-not (Test-Path $Kubeconfig)){
        Fail "Kubeconfig path '$Kubeconfig' not found"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using kubeconfig: $env:KUBECONFIG"
} elseif(-not $env:KUBECONFIG){
    Fail "KUBECONFIG not set and -Kubeconfig not provided. Export KUBECONFIG or pass -Kubeconfig <path>."
} else {
    Write-Host "Using existing KUBECONFIG: $env:KUBECONFIG"
}

# verify tools
foreach($tool in @('kubectl','helm')){
    if(-not (Get-Command $tool -ErrorAction SilentlyContinue)){
        Fail "$tool is not installed or not on PATH. Please install it and retry."
    }
}
if($AcrUsername -and -not $AcrPassword){ Fail "If you provide -AcrUsername you must also provide -AcrPassword" }
if( ($AzDevOpsToken -or $AzDevOpsPool -or $AzDevOpsPoolLinux -or $AzDevOpsPoolWindows) -and -not ($AzureDevOpsOrgUrl -and $AzDevOpsToken) ){
    Fail "If you provide any AzDevOps credential parameter you must provide both -AzureDevOpsOrgUrl and -AzDevOpsToken"
}

# Decide per-OS pool values (backwards compatible with -AzDevOpsPool)
$poolLinux = if($AzDevOpsPoolLinux){ $AzDevOpsPoolLinux } elseif($AzDevOpsPool){ $AzDevOpsPool } else { $null }
$poolWindows = if($AzDevOpsPoolWindows){ $AzDevOpsPoolWindows } elseif($AzDevOpsPool){ $AzDevOpsPool } else { $null }

# If no explicit pool names were provided, default to the canonical derived names
# so the generated values and subsequent resolver use predictable pool names.
if((-not $poolLinux) -and $InstanceNumber){
    $poolLinux = "KubernetesPoolLinux$InstanceNumber"
    Write-Host "No explicit Linux pool name provided; defaulting to $poolLinux"
}
if((-not $poolWindows) -and $InstanceNumber){
    $poolWindows = "KubernetesPoolWindows$InstanceNumber"
    Write-Host "No explicit Windows pool name provided; defaulting to $poolWindows"
}

# Helper to safely quote YAML single-quoted scalars (escape any single quotes)
function QuoteYaml([string]$s){
    if($null -eq $s){ return "''" }
    $escaped = $s -replace "'", "''"
    return "'" + $escaped + "'"
}

# ensure Azure DevOps agent pools (optional)
function Ensure-Pool([string]$orgUrl, [string]$pat, [string]$poolName){
    $authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $pat))
    $headers = @{ Authorization = $authHeader }
    $apiVersion = '7.1-preview.1'
    $getUri = "$orgUrl/_apis/distributedtask/pools?poolName=$([Uri]::EscapeDataString($poolName))&api-version=$apiVersion"
    try{
        $resp = Invoke-RestMethod -Method Get -Uri $getUri -Headers $headers -ErrorAction Stop
        if($resp.count -gt 0){ Write-Host "Pool $poolName exists (id=$($resp.value[0].id))"; return $resp.value[0].id }
    } catch {
        # continue to try create
    }
    Write-Host "Creating pool $poolName"
    $createUri = "$orgUrl/_apis/distributedtask/pools?api-version=$apiVersion"
    $body = @{ name = $poolName } | ConvertTo-Json -Compress
    $created = Invoke-RestMethod -Method Post -Uri $createUri -Headers ($headers + @{ 'Content-Type'='application/json' }) -Body $body -ErrorAction Stop
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
if($EnsureAzDoPools.IsPresent){ $shouldEnsurePools = $true }
if($AzDevOpsToken -and $AzureDevOpsOrgUrl){ $shouldEnsurePools = $true }
if($shouldEnsurePools){
    # Choose PAT: prefer explicit parameter, else env var (pipeline typical)
    $pat = if($AzDevOpsToken){ $AzDevOpsToken } else { $env:AZDO_PAT }
    if(-not $pat){ Write-Warning 'No AzDo PAT supplied (AzDevOpsToken param or AZDO_PAT env); skipping pool creation' } else {
    # Use the single canonical Azure DevOps org URL parameter
    $org = $AzureDevOpsOrgUrl
        if(-not $org){ Write-Warning 'No Azure DevOps org URL available; skipping pool creation' } else {
            if($DeployLinux){ Ensure-Pool $org $pat "KubernetesPoolLinux$InstanceNumber" | Out-Null }
            if($DeployWindows){ Ensure-Pool $org $pat "KubernetesPoolWindows$InstanceNumber" | Out-Null }
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
switch($LinuxImageVariant){
    'ubuntu22' { $linuxRepo = "$AcrName.azurecr.io/linux-sh-agent-ubuntu22" }
    'dind'     { $linuxRepo = "$AcrName.azurecr.io/linux-sh-agent-dind" }
    default    { $linuxRepo = "$AcrName.azurecr.io/linux-sh-agent-docker" }
}
$winRepo = "$AcrName.azurecr.io/windows-sh-agent-$WindowsVersion"

$yamlLines = @()

# If Acr credentials were provided, build regsecret block with decoded JSON so Helm stringData is valid
if($AcrUsername -and $AcrPassword){
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
$yamlLines += '  image:'
$yamlLines += ('    repository: ' + $linuxRepo)
$yamlLines += "    tag: latest"
$yamlLines += 'windows:'
$yamlLines += ('  enabled: ' + $enabledWindows)
$yamlLines += '  image:'
$yamlLines += ('    repository: ' + $winRepo)
$yamlLines += "    tag: latest"
$yamlLines += 'common:'
$yamlLines += ('  instance: ' + $InstanceNumber)
$yamlLines += ('linuxNamespace: az-devops-linux-' + $InstanceNumber)
$yamlLines += ('windowsNamespace: az-devops-windows-' + $InstanceNumber)

# If AzDevOps credentials were provided, add secret data for linux and windows so Helm creates the azdevops secret
# Accept either -AzDevOpsUrl (legacy) or -AzureDevOpsOrgUrl (preferred) as the organization URL
# Normalize to canonical $AzureDevOpsOrgUrl variable for downstream use
$orgUrl = $null
if($AzDevOpsUrl){
    # map legacy name to canonical variable if not already set
    if(-not $AzureDevOpsOrgUrl){ $AzureDevOpsOrgUrl = $AzDevOpsUrl }
    $orgUrl = $AzureDevOpsOrgUrl
} elseif($AzureDevOpsOrgUrl){
    $orgUrl = $AzureDevOpsOrgUrl
}
function Maybe-DecodeBase64([string]$s){
    if(-not $s){ return $s }
    # Heuristic: if the value looks like base64 (long alnum + / + + and optional = padding) try to decode
    if($s -match '^[A-Za-z0-9+/=]{16,}$'){
        try{
            $bytes = [System.Convert]::FromBase64String($s)
            $dec = [System.Text.Encoding]::UTF8.GetString($bytes)
            if($dec -match '^https?://'){ return $dec }
        } catch { }
    }
    return $s
}
if($orgUrl -and $AzDevOpsToken){
    # Defensive: if someone passed a base64 string here (chart defaults used base64 historically), decode it
    $orgUrl = Maybe-DecodeBase64 $orgUrl
    # Linux secret
    $yamlLines += 'secretlinux:'
    $yamlLines += ('  name: azdevops')
    $yamlLines += '  data:'
    if($poolLinux){ $yamlLines += ('    AZP_POOL_VALUE: ' + (QuoteYaml $poolLinux)) }
    $yamlLines += ('    AZP_TOKEN_VALUE: ' + (QuoteYaml $AzDevOpsToken))
    $yamlLines += ('    AZP_URL_VALUE: ' + (QuoteYaml $orgUrl))

    # Windows secret
    $yamlLines += 'secretwindows:'
    $yamlLines += ('  name: azdevops')
    $yamlLines += '  data:'
    if($poolWindows){ $yamlLines += ('    AZP_POOL_VALUE: ' + (QuoteYaml $poolWindows)) }
    $yamlLines += ('    AZP_TOKEN_VALUE: ' + (QuoteYaml $AzDevOpsToken))
    $yamlLines += ('    AZP_URL_VALUE: ' + (QuoteYaml $orgUrl))
}

# If we have AzDO info available (via token or env AZDO_PAT) try to resolve pool IDs for KEDA ScaledObject triggers
$patForPools = if($AzDevOpsToken){ $AzDevOpsToken } elseif($env:AZDO_PAT){ $env:AZDO_PAT } else { $null }
if($patForPools -and $orgUrl){
    # Initialize pool ID variables so referencing them is safe under StrictMode
    $linuxPoolId = $null
    $windowsPoolId = $null
    try{
        Write-Host "Resolving Azure DevOps pool IDs for pool names: linux='$poolLinux' windows='$poolWindows'"
        $authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $patForPools))
        $headers = @{ Authorization = $authHeader }
        # Query pools by name; use the distributedtask/pools endpoint
        if($poolLinux){
            $q = "$orgUrl/_apis/distributedtask/pools?poolName=$([Uri]::EscapeDataString($poolLinux))&api-version=7.1-preview.1"
            $resp = Invoke-RestMethod -Method Get -Uri $q -Headers $headers -ErrorAction Stop
            if($resp.count -gt 0){ $linuxPoolId = $resp.value[0].id }
        }
        if($poolWindows){
            $q = "$orgUrl/_apis/distributedtask/pools?poolName=$([Uri]::EscapeDataString($poolWindows))&api-version=7.1-preview.1"
            $resp = Invoke-RestMethod -Method Get -Uri $q -Headers $headers -ErrorAction Stop
            if($resp.count -gt 0){ $windowsPoolId = $resp.value[0].id }
        }
        # Emit poolID section -- empty strings when unresolved
        $yamlLines += 'poolID:'
        if($linuxPoolId){ $yamlLines += ('  linux: ' + $linuxPoolId) } else { $yamlLines += '  linux: ""' }
        if($windowsPoolId){ $yamlLines += ('  windows: ' + $windowsPoolId) } else { $yamlLines += '  windows: ""' }
        Write-Host "Resolved pool IDs: linux=$linuxPoolId windows=$windowsPoolId"
    } catch {
        Write-Warning "Failed to resolve pool IDs from Azure DevOps: $($_.Exception.Message)"
        # still emit empty poolID keys to avoid template errors
        $yamlLines += 'poolID:'
        $yamlLines += '  linux: ""'
        $yamlLines += '  windows: ""'
    }
} else {
    # No AzDO credentials; emit empty poolID entries so the chart compiles but KEDA won't be functional until set
    $yamlLines += 'poolID:'
    $yamlLines += '  linux: ""'
    $yamlLines += '  windows: ""'
}

$yamlPath = Join-Path -Path $env:TEMP -ChildPath "helm-values-override-$InstanceNumber.yaml"
$yamlLines | Out-File -FilePath $yamlPath -Encoding utf8
Write-Host "Wrote Helm values override to $yamlPath"
# Diagnostic: print regsecret stanza if present so CI logs include the value presence (not secrets)
Write-Host '--- regsecret stanza (diagnostic) ---'
$yamlLines | Where-Object { $_ -like 'regsecret*' -or $_ -like '  data:*' -or $_ -like '    DOCKER_CONFIG_JSON_VALUE*' } | ForEach-Object { Write-Host $_ }
Write-Host '--- end regsecret stanza ---'

# If running inside a pipeline, copy the generated values file into the pipeline's
# artifact staging directory so the PublishPipelineArtifact task can find it.
if($env:BUILD_ARTIFACTSTAGINGDIRECTORY){
    try{
        if(-not (Test-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY)){
            New-Item -ItemType Directory -Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY | Out-Null
        }
        $dest = Join-Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY 'helm-values-override.yaml'
        Copy-Item -Path $yamlPath -Destination $dest -Force
        Write-Host "Copied Helm values override to $dest for pipeline artifact publish"
    } catch {
        Write-Warning "Failed to copy helm values override to Build.ArtifactStagingDirectory: $($_.Exception.Message)"
    }
}

if($WriteValuesOnly.IsPresent){
    Write-Host "WriteValuesOnly set - exiting after creating values file: $yamlPath"
    exit 0
}

# Ensure namespaces (do not create a separate release namespace anymore)
# We create only the per-OS namespaces; the Helm release will be installed into one of them.
$linuxNs = "az-devops-linux-$InstanceNumber"
$winNs = "az-devops-windows-$InstanceNumber"
$namespaces = @($linuxNs, $winNs)
# Choose release namespace: prefer Linux if Linux is being deployed, otherwise Windows
$releaseNamespace = if($DeployLinux.IsPresent){ $linuxNs } elseif($DeployWindows.IsPresent){ $winNs } else { $linuxNs }
foreach($ns in $namespaces){
    try{ kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f - } catch { Write-Warning ("Failed to ensure namespace {0}: {1}" -f $ns, $_.Exception.Message) }
}

# Optional: create regsecret in target namespaces if AcrUsername/AcrPassword provided
if($AcrUsername -and $AcrPassword){
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
    $tmp = Join-Path $env:TEMP "dockerconfig-$InstanceNumber.json"
    [System.IO.File]::WriteAllText($tmp, $dockerConfigJson)

    foreach($ns in $targetNs){
        Write-Host "Removing existing docker-registry secret 'regsecret' in namespace $ns' so Helm can create it"
        kubectl -n $ns delete secret regsecret --ignore-not-found
    }

    # Do NOT create the secret here; Helm will create it from the values block we injected above.
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}

# Render and deploy Helm chart
$releaseName = "az-selfhosted-agents-$InstanceNumber"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptRoot '..\..\')
$chartPath = Join-Path $repoRoot 'helm-charts-v2/az-selfhosted-agents'
if(-not (Test-Path $chartPath)){
    Fail "Chart path $chartPath not found in repository. Run this script from the repository root or adjust path." 
}

Write-Host "Rendering chart templates and installing release $releaseName to namespace $releaseNamespace"
try{
    # Ensure any stale regsecret is removed before Helm attempts to create/patch it.
    try{ & kubectl -n $releaseNamespace delete secret regsecret --ignore-not-found } catch { Write-Host "Warning: failed to delete existing regsecret in $releaseNamespace (non-fatal)" }
    helm dependency update $chartPath | Out-Null
    helm upgrade --install $releaseName $chartPath --namespace $releaseNamespace --create-namespace -f $yamlPath --wait --timeout 10m
    Write-Host "Helm release $releaseName deployed to namespace $releaseNamespace"
} catch {
    Write-Warning "Helm deployment reported an error: $($_.Exception.Message)"
}
# Post-deploy verification: print applied helm values and confirm poolID entries are non-empty
Write-Host "Post-deploy: verifying applied Helm values for release $releaseName in namespace $releaseNamespace"
try{
    $appliedValues = & helm get values $releaseName -n $releaseNamespace --all 2>$null | Out-String
    Write-Host '--- helm get values (applied) ---'
    Write-Host $appliedValues
    Write-Host '--- end helm values ---'

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

    if(-not $linuxPoolID -or $linuxPoolID -eq 'x'){
        Write-Warning "poolID.linux appears unset or still placeholder ('$linuxPoolID'). KEDA ScaledObject may fail to parse poolID."
    } else {
        Write-Host "Resolved poolID.linux = $linuxPoolID"
    }
    if(-not $windowsPoolID -or $windowsPoolID -eq 'y'){
        Write-Warning "poolID.windows appears unset or still placeholder ('$windowsPoolID'). KEDA ScaledObject may fail to parse poolID."
    } else {
        Write-Host "Resolved poolID.windows = $windowsPoolID"
    }
} catch {
    Write-Warning "Failed to retrieve applied helm values for ${releaseName}: $($_.Exception.Message)"
}

Write-Host "Post-deploy: list pods and deployments in release namespace $releaseNamespace"
kubectl get pods -n $releaseNamespace -o wide || true
kubectl get deployment -n $releaseNamespace -o wide || true

Write-Host "Done. If any pods are ImagePullBackOff/ErrImagePull, ensure a docker-registry secret named 'regsecret' exists in the pod namespace and points to $AcrName.azurecr.io"
