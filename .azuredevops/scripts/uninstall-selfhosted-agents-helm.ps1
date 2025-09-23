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
    [Parameter(Mandatory=$false)] [string] $Kubeconfig,
    [Parameter(Mandatory=$false)] [string] $InstanceNumber = '003',
    # Use booleans so we can have sensible defaults (true) while remaining easy to call
    [Parameter(Mandatory=$false)] [bool] $RemoveKeda = $true,
    [Parameter(Mandatory=$false)] [bool] $RemoveKedaCRDs = $true,
    [Parameter(Mandatory=$false)] [bool] $RemoveNamespaces = $true,
    [Parameter(Mandatory=$false)] [bool] $RemoveSecrets = $true,
    [Parameter(Mandatory=$false)] [bool] $ForceFinalize = $true
    ,
    [Parameter(Mandatory=$false)] [string] $AzDevOpsUrl,
    # Backwards-compatible alias used by pipeline templates
    [Parameter(Mandatory=$false)] [string] $AzureDevOpsOrgUrl,
    [Parameter(Mandatory=$false)] [string] $AzDevOpsToken,
    [Parameter(Mandatory=$false)] [bool] $RemoveAzDoPools = $true,
    # Pipeline-compatible flags (some pipelines pass these names)
    [Parameter(Mandatory=$false)] [object] $RemoveLinux = $true,
    [Parameter(Mandatory=$false)] [object] $RemoveWindows = $true,
    [Parameter(Mandatory=$false)] [object] $DeleteAgentPools = $true,
    [Parameter(Mandatory=$false)] [string] $ConfirmDeletion = 'YES',
    # Accept object here and coerce to bool so callers can pass 'true'/'false' strings without binding errors
    [Parameter(Mandatory=$false)] [object] $VerboseHttp = $false
)

function ConvertTo-Bool([object]$v){
    if($v -is [bool]){ return $v }
    if($null -eq $v){ return $false }
    try{
        $s = $v.ToString().Trim().ToLowerInvariant()
    } catch { return $false }
    switch($s){
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
if($PSBoundParameters.ContainsKey('DeleteAgentPools')){
    $RemoveAzDoPools = $DeleteAgentPools
}

# Ensure ConfirmDeletion is respected if provided (pipeline already validates it)
if($PSBoundParameters.ContainsKey('ConfirmDeletion')){
    if(($ConfirmDeletion -ne 'YES') -and ($ConfirmDeletion -ne 'Yes')){
        Fail "ConfirmDeletion must be 'YES' to proceed. Current: '$ConfirmDeletion'"
    }
}

function Fail([string]$msg){ Write-Error $msg; exit 1 }

Write-Host "Starting uninstall script (instance=$InstanceNumber)"

# Support legacy and new parameter names: normalize to canonical $AzureDevOpsOrgUrl
if($AzDevOpsUrl -and -not $AzureDevOpsOrgUrl){ $AzureDevOpsOrgUrl = $AzDevOpsUrl }
if($AzureDevOpsOrgUrl -and -not $AzDevOpsUrl){ $AzDevOpsUrl = $AzureDevOpsOrgUrl }

# kubeconfig handling (mirror of deploy script behavior)
if($Kubeconfig){
    if(-not (Test-Path $Kubeconfig)){
        Fail "Kubeconfig path '$Kubeconfig' not found"
    }
    $env:KUBECONFIG = (Resolve-Path $Kubeconfig).Path
    Write-Host "Using kubeconfig: $env:KUBECONFIG"
} elseif(-not $env:KUBECONFIG){
    Write-Warning "KUBECONFIG not set and -Kubeconfig not provided. Will attempt to use default kubectl context."
} else {
    Write-Host "Using existing KUBECONFIG: $env:KUBECONFIG"
}

# verify tools
foreach($tool in @('kubectl','helm')){
    if(-not (Get-Command $tool -ErrorAction SilentlyContinue)){
        Fail "$tool is not installed or not on PATH. Please install it and retry."
    }
}

function Exec([string]$cmd){
    Write-Host "> $cmd"
    try{
        Invoke-Expression $cmd
    } catch {
        Write-Warning ("Command failed: {0} -- {1}" -f $cmd, $_.Exception.Message)
    }
}

function Remove-HelmRelease([string]$release, [string]$namespace){
    if(-not $release){ return }
    Write-Host "Uninstalling Helm release '$release' in namespace '$namespace' (if present)"
    try{
        helm uninstall $release --namespace $namespace --wait --timeout 5m 2>&1 | Out-Null
        Write-Host "Requested uninstall of release $release"
    } catch {
        Write-Warning ("helm uninstall reported an issue: {0}" -f $_.Exception.Message)
    }
}

function Remove-NS([string]$ns){
    if(-not $ns){ return }
    Write-Host "Deleting namespace '$ns' (if present)"
    try{
        kubectl delete namespace $ns --ignore-not-found --wait --timeout=5m 2>$null | Out-Null
    } catch {
        Write-Warning ("kubectl delete namespace {0} returned error: {1}" -f $ns, $_.Exception.Message)
    }

    # If namespace still exists and is Terminating, optionally clear finalizers
    try{
        $nsJson = kubectl get namespace $ns -o json 2>$null
        if($nsJson){
            $j = $nsJson | ConvertFrom-Json -ErrorAction SilentlyContinue
            if($j -and $j.status -and $j.status.phase -eq 'Terminating'){
                if($ForceFinalize){
                    Write-Host "Namespace $ns is Terminating; removing finalizers to force deletion"
                    # Patch finalizers to empty array
                    kubectl patch namespace $ns -p '{"metadata":{"finalizers":[]}}' --type=merge 2>&1 | Out-Null
                    Write-Host "Patched finalizers on $ns; attempting delete again"
                    kubectl delete namespace $ns --ignore-not-found --wait --timeout=2m 2>$null | Out-Null
                } else {
                    Write-Warning "Namespace $ns is Terminating and ForceFinalize is not set; leaving as-is"
                }
            }
        }
    } catch {
        Write-Warning ("Failed to inspect/patch namespace {0}: {1}" -f $ns, $_.Exception.Message)
    }
}

# Compose target names
$baseNs = "az-devops-$InstanceNumber" # legacy/compat namespace (may be absent)
$linuxNs = "az-devops-linux-$InstanceNumber"
$winNs = "az-devops-windows-$InstanceNumber"
$releaseName = "az-selfhosted-agents-$InstanceNumber"

# Azure DevOps pool names created by the deploy script
$azPoolLinux = "KubernetesPoolLinux$InstanceNumber"
$azPoolWindows = "KubernetesPoolWindows$InstanceNumber"

function Remove-Pool([string]$orgUrl, [string]$pat, [string]$poolName){
    if(-not ($orgUrl -and $pat -and $poolName)){ return }
    Write-Host "Looking for Azure DevOps pool '$poolName' at $orgUrl"
    $authHeader = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $pat))
    # Ask for JSON and provide a User-Agent so the service returns JSON rather than HTML sign-in pages
    $headers = @{
        Authorization = $authHeader
        Accept = 'application/json'
        'Content-Type' = 'application/json'
        'User-Agent' = 'uninstall-selfhosted-agents-ps'
    }

    # Try agent pools endpoint first, then fallback to deployment pools (some pools are created via deployment API)
    $apiVersions = @('7.1-preview.1','6.0-preview.1','5.1-preview.1')
    $found = $false
    function Get-ResponseBodyAndStatus($respObj){
        try{
            if($null -eq $respObj){ return @{ Status = $null; Body = $null } }
            # System.Net.WebException.Response -> WebResponse with GetResponseStream
            if($respObj -is [System.Net.WebResponse]){
                $status = $respObj.StatusCode 2>$null
                try{ $body = (New-Object System.IO.StreamReader($respObj.GetResponseStream())).ReadToEnd() } catch { $body = $null }
                return @{ Status = $status; Body = $body }
            }
            # PowerShell Core often exposes HttpResponseMessage
            if($respObj -is [System.Net.Http.HttpResponseMessage]){
                $status = $respObj.StatusCode
                $body = $respObj.Content.ReadAsStringAsync().Result
                return @{ Status = $status; Body = $body }
            }
            # Fallback: try properties
            if($respObj.StatusCode -or $respObj.Content){
                $status = $respObj.StatusCode 2>$null
                try{ $body = $respObj.Content.ReadAsStringAsync().Result } catch { $body = $null }
                return @{ Status = $status; Body = $body }
            }
        } catch { }
        return @{ Status = $null; Body = $null }
    }

    foreach($apiVersion in $apiVersions){
        $getUri = "$orgUrl/_apis/distributedtask/pools?poolName=$([Uri]::EscapeDataString($poolName))&api-version=$apiVersion"
        try{
            if($VerboseHttp){ Write-Host "HTTP GET $getUri" }
            $resp = Invoke-RestMethod -Method Get -Uri $getUri -Headers $headers -ErrorAction Stop
            if($VerboseHttp){ Write-Host "HTTP GET returned:"; $resp | ConvertTo-Json -Depth 5 | Write-Host }
            if($resp.count -gt 0 -and $resp.value[0].id){
                $id = $resp.value[0].id
                Write-Host "Found agent pool $poolName id=$id (api-version=$apiVersion); attempting delete via distributedtask/pools"
                foreach($delVer in $apiVersions){
                    # Use $($id) to avoid parser ambiguity when variable is adjacent to '?'
                    $delUri = "$orgUrl/_apis/distributedtask/pools/$($id)?api-version=$delVer"
                    try{
                        if($VerboseHttp){ Write-Host "HTTP DELETE $delUri" }
                        $delResp = Invoke-WebRequest -Method Delete -Uri $delUri -Headers $headers -ErrorAction Stop
                        if($VerboseHttp){ Write-Host "HTTP DELETE returned status: $($delResp.StatusCode)" }
                        Write-Host "Deleted agent pool $poolName (id=$id) using api-version=$delVer"
                        $found = $true
                        break
                    } catch {
                        $lastErr = $_
                        if($_.Exception -and $_.Exception.Response -and $VerboseHttp){
                            try{
                                    $info = Get-ResponseBodyAndStatus $_.Exception.Response
                                    Write-Warning ("HTTP DELETE failed for {0}: Status={1}" -f $delUri, $info.Status)
                                    if($info.Body){ Write-Host "Response body:"; Write-Host $info.Body }
                            } catch { }
                        }
                    }
                }
                if(-not $found){
                    Write-Warning ("Failed to delete agent pool {0}: {1}" -f $poolName, $lastErr.Exception.Message)
                    Write-Warning "Hint: ensure the PAT has 'Agent Pools (read & manage)' scope and your account is a Collection Administrator."
                }
                break
            }
            } catch {
                # Try to surface HTTP status and body when available (helps explain HTML sign-in pages / 401s)
                if($_.Exception -and $_.Exception.Response){
                    try{
                        $info = Get-ResponseBodyAndStatus $_.Exception.Response
                        if($VerboseHttp){ Write-Warning ("HTTP GET failed for {0}: {1} - Status: {2}" -f $getUri, $_.Exception.Message, $info.Status) }
                        if($VerboseHttp -and $info.Body){ Write-Host "Response body:"; Write-Host $info.Body }
                    } catch {
                        if($VerboseHttp){ Write-Warning ("HTTP GET failed for {0}: {1} (failed to read response body)" -f $getUri, $_.Exception.Message) }
                    }
                } else {
                    if($VerboseHttp){ Write-Warning ("HTTP GET failed for {0}: {1}" -f $getUri, $_.Exception.Message) }
                }
                # ignore and continue, we'll try deploymentpools next
            }
    }

    if(-not $found){
        # Try deployment pools endpoint as a fallback
        foreach($apiVersion in $apiVersions){
            $getUri2 = "$orgUrl/_apis/distributedtask/deploymentpools?poolName=$([Uri]::EscapeDataString($poolName))&api-version=$apiVersion"
            try{
                if($VerboseHttp){ Write-Host "HTTP GET $getUri2" }
                $resp2 = Invoke-RestMethod -Method Get -Uri $getUri2 -Headers $headers -ErrorAction Stop
                if($VerboseHttp){ Write-Host "HTTP GET returned:"; $resp2 | ConvertTo-Json -Depth 5 | Write-Host }
                if($resp2.count -gt 0 -and $resp2.value[0].id){
                    $id2 = $resp2.value[0].id
                    Write-Host "Found deployment pool $poolName id=$id2 (api-version=$apiVersion); attempting delete via distributedtask/deploymentpools"
                    foreach($delVer in $apiVersions){
                        $delUri2 = "$orgUrl/_apis/distributedtask/deploymentpools/$($id2)?api-version=$delVer"
                        try{
                            if($VerboseHttp){ Write-Host "HTTP DELETE $delUri2" }
                            $delResp2 = Invoke-WebRequest -Method Delete -Uri $delUri2 -Headers $headers -ErrorAction Stop
                            if($VerboseHttp){ Write-Host "HTTP DELETE returned status: $($delResp2.StatusCode)" }
                            Write-Host "Deleted deployment pool $poolName (id=$id2) using api-version=$delVer"
                            $found = $true
                            break
                        } catch {
                            $lastErr = $_
                            if($_.Exception -and $_.Exception.Response -and $VerboseHttp){
                                try{
                                    $info = Get-ResponseBodyAndStatus $_.Exception.Response
                                    Write-Warning ("HTTP DELETE failed for {0}: Status={1}" -f $delUri2, $info.Status)
                                    if($info.Body){ Write-Host "Response body:"; Write-Host $info.Body }
                                } catch { }
                            }
                        }
                    }
                    if(-not $found){
                        Write-Warning ("Failed to delete deployment pool {0}: {1}" -f $poolName, $lastErr.Exception.Message)
                        Write-Warning "Hint: ensure the PAT has 'Deployment pools (read & manage)' scope or equivalent permissions."
                    }
                    break
                }
                } catch {
                    if($VerboseHttp){
                        if($_.Exception -and $_.Exception.Response){
                            try{
                                $info = Get-ResponseBodyAndStatus $_.Exception.Response
                                Write-Warning ("HTTP GET failed for {0}: {1} - Status: {2}" -f $getUri2, $_.Exception.Message, $info.Status)
                                if($info.Body){ Write-Host "Response body:"; Write-Host $info.Body }
                            } catch {
                                Write-Warning ("HTTP GET failed for {0}: {1} (failed to read response body)" -f $getUri2, $_.Exception.Message)
                            }
                        } else {
                            Write-Warning ("HTTP GET failed for {0}: {1}" -f $getUri2, $_.Exception.Message)
                        }
                    }
                # ignore and continue
            }
        }
    }

    if(-not $found){ Write-Host "Pool $poolName not found or not deletable via API; you can delete it from Organization settings -> Agent pools in the web UI." }
}

# 1) Uninstall the main Helm release
# Prefer uninstalling from linux namespace if present, else windows, else legacy base namespace
$releaseNsFound = $null
try{
    $out = kubectl get ns $linuxNs -o json 2>$null | Out-String
    if($out -and $out.Trim().Length -gt 0){ $releaseNsFound = $linuxNs }
} catch { }
if(-not $releaseNsFound){
    try{ $out = kubectl get ns $winNs -o json 2>$null | Out-String ; if($out -and $out.Trim().Length -gt 0){ $releaseNsFound = $winNs } } catch { }
}
if(-not $releaseNsFound){
    try{ $out = kubectl get ns $baseNs -o json 2>$null | Out-String ; if($out -and $out.Trim().Length -gt 0){ $releaseNsFound = $baseNs } } catch { }
}
if($releaseNsFound){
    Remove-HelmRelease -release $releaseName -namespace $releaseNsFound
} else {
    Write-Warning "No candidate namespace found for Helm release $releaseName; attempting uninstall in legacy namespace $baseNs"
    Remove-HelmRelease -release $releaseName -namespace $baseNs
}

# Optionally remove Azure DevOps pools
if($RemoveAzDoPools){
    $pat = $AzDevOpsToken; if(-not $pat){ $pat = $env:AZDO_PAT }
    if(-not $pat){ Write-Warning 'AZDO_PAT / AzDevOpsToken not provided; skipping AzDevOps pool removal' } else {
        if(-not $AzureDevOpsOrgUrl){ Write-Warning 'AzureDevOpsOrgUrl not provided; skipping pool removal' } else {
            Remove-Pool -orgUrl $AzureDevOpsOrgUrl -pat $pat -poolName $azPoolLinux
            Remove-Pool -orgUrl $AzureDevOpsOrgUrl -pat $pat -poolName $azPoolWindows
        }
    }
}

# 2) Optionally remove regsecret and azdevops secret from target namespaces
if($RemoveSecrets){
    # Legacy/base namespace
    try{ Write-Host "Removing 'regsecret' and 'azdevops' secrets in namespace $baseNs (ignore if missing)"; kubectl -n $baseNs delete secret regsecret --ignore-not-found 2>$null | Out-Null } catch { }
    try{ kubectl -n $baseNs delete secret azdevops --ignore-not-found 2>$null | Out-Null } catch { }

    if($RemoveLinux){
        try{ Write-Host "Removing 'regsecret' and 'azdevops' secrets in namespace $linuxNs (ignore if missing)"; kubectl -n $linuxNs delete secret regsecret --ignore-not-found 2>$null | Out-Null } catch { }
        try{ kubectl -n $linuxNs delete secret azdevops --ignore-not-found 2>$null | Out-Null } catch { }
    }

    if($RemoveWindows){
        try{ Write-Host "Removing 'regsecret' and 'azdevops' secrets in namespace $winNs (ignore if missing)"; kubectl -n $winNs delete secret regsecret --ignore-not-found 2>$null | Out-Null } catch { }
        try{ kubectl -n $winNs delete secret azdevops --ignore-not-found 2>$null | Out-Null } catch { }
    }
}

# 3) Uninstall KEDA (default behavior)
if($RemoveKeda){
    Write-Host "Uninstalling KEDA (helm release 'keda' in namespace 'keda')"
    Remove-HelmRelease -release 'keda' -namespace 'keda'
    # delete the keda namespace
    if($RemoveNamespaces){
        Remove-NS -ns 'keda'
    }
    if($RemoveKedaCRDs){
        Write-Host "Removing KEDA CRDs (if present)"
        $crds = @('scaledobjects.keda.sh','scaledjobs.keda.sh','triggerauthentications.keda.sh','clustertriggerauthentications.keda.sh')
        foreach($c in $crds){
            try{ kubectl delete crd $c --ignore-not-found 2>$null | Out-Null } catch { Write-Warning ("Failed to delete CRD {0}: {1}" -f $c, $_.Exception.Message) }
        }
    }
}

# 4) Remove the agent namespaces
if($RemoveNamespaces){
    # Remove per-OS namespaces according to flags; also attempt legacy base namespace if present
    if($RemoveLinux){ Remove-NS -ns $linuxNs }
    if($RemoveWindows){ Remove-NS -ns $winNs }
    # Always attempt legacy base namespace removal when RemoveNamespaces is true
    Remove-NS -ns $baseNs
}

# 5) Final cleanup: list remaining resources for user's inspection
Write-Host "Cleanup requested completed. Current Helm releases:"
try{ helm list -A } catch { Write-Warning "helm list failed" }

Write-Host "Remaining namespaces (filtered by az-devops* and keda):"
try{ kubectl get namespaces -o wide --no-headers | Where-Object { $_ -match 'az-devops|keda' } | ForEach-Object { Write-Host $_ } } catch { Write-Warning "kubectl get namespaces failed" }

Write-Host "If any namespace remains in Terminating state you can re-run this script with -ForceFinalize to remove finalizers and force deletion."
Write-Host "Done."
