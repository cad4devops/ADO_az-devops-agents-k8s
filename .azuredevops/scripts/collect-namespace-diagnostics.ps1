param(
    [string]$Namespace = 'az-devops-003'
)

$ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
$outDir = Join-Path (Get-Location) "ns-diag-$Namespace-$ts"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

function SaveFile($name, $script) {
    $path = Join-Path $outDir $name
    Write-Output "Saving $path"
    try {
        & pwsh -NoProfile -Command $script | Out-File -FilePath $path -Encoding utf8 -Force
    } catch {
        "ERROR running: $script -> $_" | Out-File -FilePath $path -Encoding utf8 -Force
    }
}

# Namespace JSON/YAML
SaveFile "ns-$Namespace.json" "kubectl get namespace $Namespace -o json"
SaveFile "ns-$Namespace.yaml" "kubectl get namespace $Namespace -o yaml"

# Namespace events and cluster events mentioning the namespace
SaveFile "events-ns-$Namespace.txt" "kubectl get events --all-namespaces --field-selector involvedObject.kind=Namespace,involvedObject.name=$Namespace -o wide"
SaveFile "events-cluster-$Namespace.json" "kubectl get events --all-namespaces -o json | ConvertTo-Json"

# API aggregation and CRDs
SaveFile "apiservices.json" "kubectl get apiservices -o json"
SaveFile "apiservices.txt" "kubectl get apiservices -o wide"
SaveFile "crd-list.txt" "kubectl get crd -o name"
SaveFile "crds.json" "kubectl get crd -o json"

# kube-system pods and potential controller-manager pods
SaveFile "kube-system-pods.txt" "kubectl get pods -n kube-system -o wide"

# Try to capture any resources that mention the namespace (best-effort, may be large)
Write-Output "Gathering cluster-wide JSON may be slow; saving to all-namespaces.json"
try {
    kubectl get --all-namespaces -o json > (Join-Path $outDir 'all-namespaces.json')
    Write-Output "Searching all-namespaces.json for string: $Namespace"
    Select-String -Path (Join-Path $outDir 'all-namespaces.json') -Pattern $Namespace -SimpleMatch -Context 2 | Select-Object -First 500 | Out-File (Join-Path $outDir 'all-namespaces-matches.txt') -Encoding utf8
} catch {
    "ERROR gathering all-namespaces: $_" | Out-File (Join-Path $outDir 'all-namespaces-error.txt') -Encoding utf8
}

# Attempt to GET finalize raw (may return MethodNotAllowed)
SaveFile "finalize-raw.txt" "kubectl get --raw \"/api/v1/namespaces/$Namespace/finalize\" 2>&1"

# Summarize
Write-Output "Created diagnostics folder: $outDir"

# Zip it
$zip = "$outDir.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($outDir, $zip)
Write-Output "Wrote diagnostics bundle: $zip"
