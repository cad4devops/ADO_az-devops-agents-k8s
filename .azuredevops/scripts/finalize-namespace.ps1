param(
    [string]$Namespace = 'az-devops-003',
    [switch]$DryRun,
    [switch]$ForceDelete,
    [switch]$Finalize,
    [switch]$YesToAll
)

# Simple logger
$time = (Get-Date).ToString('yyyyMMdd-HHmmss')
$logFile = Join-Path -Path (Get-Location) -ChildPath "ns-cleanup-$Namespace-$time.log"
function Log {
    param([string]$s)
    $s | Tee-Object -FilePath $logFile -Append
}

Log "Starting namespace cleanup script: Namespace=$Namespace DryRun=$DryRun ForceDelete=$ForceDelete Finalize=$Finalize"

# Check kubectl available
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Log "ERROR: kubectl not found in PATH"
    throw "kubectl not available"
}

# Check helm optional
$helmAvailable = $null -ne (Get-Command helm -ErrorAction SilentlyContinue)
if (-not $helmAvailable) { Log "helm not found; helm-related info will be skipped" }

# Save audit copy of namespace
try {
    kubectl get namespace $Namespace -o json > "ns-$Namespace.json" 2>$null
    Log "Saved ns-$Namespace.json"
} catch {
    Log "ERROR: failed to save namespace JSON: $_"
}

# Show current namespace yaml
try {
    Log "\n--- Namespace YAML ---"
    kubectl get namespace $Namespace -o yaml 2>$null | ForEach-Object { Log $_ }
} catch {
    Log "ERROR: failed to get namespace yaml: $_"
}

# List namespaced resource types
$types = kubectl api-resources --verbs=list --namespaced -o name 2>$null | Sort-Object -Unique
Log "Found $(($types | Measure-Object).Count) namespaced resource types"

# Dry-run: list what exists per type
if ($DryRun) { Log "DRY RUN: will only list resources" }

$itemsFound = @()
foreach ($t in $types) {
    if (-not $t) { continue }
    try {
        $items = kubectl get -n $Namespace $t -o name --ignore-not-found 2>$null
    } catch {
        $items = $null
    }
    if ($items) {
        Log "\n=== $t ==="
        foreach ($it in $items) { Log "  $it"; $itemsFound += $it }
    }
}

if (-not $itemsFound) { Log "No standard namespaced items found." } else { Log "Total items found: $($itemsFound.Count)" }

# Force delete items if requested
if ($ForceDelete -and $itemsFound) {
    Log "\nFORCE-DELETE MODE: Deleting $($itemsFound.Count) items with --grace-period=0 --force"
    foreach ($it in $itemsFound) {
        try {
            Log "Deleting $it"
            $out = kubectl delete $it -n $Namespace --grace-period=0 --force --ignore-not-found 2>&1
            $out | ForEach-Object { Log "  $_" }
        } catch {
            Log ("Error deleting {0}: {1}" -f $it, $_)
        }
    }
}

# Search for any remaining namespaced objects with finalizers
Log "\nSearching for objects with metadata.finalizers in $Namespace..."
$foundFinalizer = $false
foreach ($t in $types) {
    if (-not $t) { continue }
    try {
        $j = kubectl get -n $Namespace $t -o json --ignore-not-found 2>$null
    } catch {
        $j = $null
    }
    if ($j) {
        try {
            $obj = $j | ConvertFrom-Json
            foreach ($item in $obj.items) {
                if ($item.metadata -and $item.metadata.finalizers) {
                    $foundFinalizer = $true
                    $line = "$($item.kind)/$($item.metadata.name) finalizers: $($item.metadata.finalizers -join ',')"
                    Log $line
                }
            }
        } catch {
            # ignore parse errors
        }
    }
}
if (-not $foundFinalizer) { Log "No namespaced objects with finalizers found." }

# If finalizers found and user opted to clear them, patch each one
if ($foundFinalizer -and ($YesToAll -or $ForceDelete)) {
    Log "\nPatching finalizers to empty for discovered objects (because ForceDelete or YesToAll was set)"
    foreach ($t in $types) {
        if (-not $t) { continue }
        try {
            $j = kubectl get -n $Namespace $t -o json --ignore-not-found 2>$null
        } catch { $j = $null }
        if ($j) {
            try {
                $obj = $j | ConvertFrom-Json
                foreach ($item in $obj.items) {
                    if ($item.metadata -and $item.metadata.finalizers) {
                        $name = $item.metadata.name
                        Log "Patching $t/$name finalizers -> []"
                        try {
                            kubectl patch $t $name -n $Namespace -p '{"metadata":{"finalizers":[]}}' --type=merge 2>&1 | ForEach-Object { Log ("  {0}" -f $_) }
                        } catch {
                            Log ("  patch failed for {0}/{1}: {2}" -f $t, $name, $_)
                        }
                    }
                }
            } catch {
                # ignore
            }
        }
    }
}

# Optionally re-run namespace finalize
if ($Finalize) {
    Log "\nRunning namespace finalize replace (posting finalize subresource)"
    # Ensure we have a namespace JSON; if not, fetch
    if (-not (Test-Path ".\ns-$Namespace.json")) {
        try { kubectl get namespace $Namespace -o json > "ns-$Namespace.json" 2>$null; Log "Saved ns-$Namespace.json" } catch { Log "Failed to save ns json: $_" }
    }
    try {
        # Prepare a finalize payload: keep name/uid/resourceVersion and ensure metadata.finalizers=[]
        $nsObj = Get-Content -Raw .\ns-$Namespace.json | ConvertFrom-Json
        $finalize = [PSCustomObject]@{
            apiVersion = 'v1'
            kind = 'Namespace'
            metadata = [PSCustomObject]@{
                name = $nsObj.metadata.name
                uid = $nsObj.metadata.uid
                resourceVersion = $nsObj.metadata.resourceVersion
                finalizers = @()
            }
        }
        $finalizeJson = $finalize | ConvertTo-Json -Depth 10
        $finalizeFile = ".\ns-$Namespace-finalize.json"
        $finalizeJson | Out-File -FilePath $finalizeFile -Encoding utf8
        Log "Wrote finalize payload to $finalizeFile"
        $out = kubectl replace --raw "/api/v1/namespaces/$Namespace/finalize" -f $finalizeFile 2>&1
        $out | ForEach-Object { Log "  $_" }
    } catch {
        Log "Finalize failed: $_"
    }
}

# Final status
Log "\nFinal namespace status:"
kubectl get namespace $Namespace -o yaml 2>&1 | ForEach-Object { Log "  $_" }

Log "Script complete. Log saved to: $logFile"
Write-Output "Done. Log: $logFile"