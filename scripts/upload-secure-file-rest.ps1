Param (
    [Parameter(Mandatory = $true)][string]$PAT,
    [Parameter(Mandatory = $true)][string]$AzureDevOpsOrg,
    [Parameter(Mandatory = $true)][string]$AzureDevOpsProjectID,
    [Parameter(Mandatory = $true)][string]$SecureNameFile2Upload,
    [Parameter(Mandatory = $true)][string]$SecureNameFilePath2Upload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info([string]$m) { Write-Host "[INFO] $m" }
function Write-Err([string]$m) { Write-Host "[ERROR] $m" -ForegroundColor Red }

if (-not (Test-Path -Path $SecureNameFilePath2Upload)) {
    Write-Err "Local file to upload not found: $SecureNameFilePath2Upload"
    exit 2
}

# Normalize org URL: allow passing either 'myorg' or full 'https://dev.azure.com/myorg'
if ($AzureDevOpsOrg -match '^https?://') {
    $orgUrl = $AzureDevOpsOrg.TrimEnd('/')
}
else {
    $orgUrl = "https://dev.azure.com/$AzureDevOpsOrg"
}

$projectUrl = "$orgUrl/$AzureDevOpsProjectID"

$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT"))
$headers = @{ Authorization = "Basic $base64AuthInfo"; Accept = 'application/json' }

try {
    Write-Info "Listing secure files in $projectUrl"
    $listUri = "$projectUrl/_apis/distributedtask/securefiles?api-version=7.1-preview.1"
    $listResp = Invoke-RestMethod -Uri $listUri -Method Get -Headers $headers -ErrorAction Stop
    $existing = $null
    
    # Defensive parsing: handle different response shapes
    # Shape 1: { value: [...] } — standard REST response
    # Shape 2: [...] — direct array
    # Shape 3: empty or null
    $secureFiles = @()
    if ($listResp) {
        if ($listResp.PSObject.Properties.Name -contains 'value') {
            # Standard shape with .value array
            if ($listResp.value -is [System.Collections.IEnumerable]) {
                $secureFiles = @($listResp.value)
            }
        }
        elseif ($listResp -is [System.Collections.IEnumerable]) {
            # Direct array
            $secureFiles = @($listResp)
        }
    }
    
    if ($secureFiles.Count -gt 0) {
        $existing = $secureFiles | Where-Object { $_.name -eq $SecureNameFile2Upload } | Select-Object -First 1
    }

    if ($existing) {
        Write-Info "Found existing secure file with id=$($existing.id). Deleting..."
        $delUri = "$projectUrl/_apis/distributedtask/securefiles/$($existing.id)?api-version=7.1-preview.1"
        Invoke-RestMethod -Uri $delUri -Method Delete -Headers $headers -ErrorAction Stop
        Write-Info "Deleted secure file id=$($existing.id)"
    }
    else {
        Write-Info "No existing secure file named '$SecureNameFile2Upload' found."
    }

    Write-Info "Uploading new secure file '$SecureNameFile2Upload' from path '$SecureNameFilePath2Upload'"
    $uploadUri = "$projectUrl/_apis/distributedtask/securefiles?api-version=7.1-preview.1&name=$([System.Uri]::EscapeDataString($SecureNameFile2Upload))"
    # Use Invoke-RestMethod to POST raw bytes
    $resp = Invoke-RestMethod -Uri $uploadUri -Method Post -Headers $headers -InFile $SecureNameFilePath2Upload -ContentType 'application/octet-stream' -ErrorAction Stop
    if ($resp -and $resp.id) {
        Write-Info "Upload succeeded. secure file id=$($resp.id)"
        exit 0
    }
    else {
        Write-Err "Upload returned unexpected response: $(ConvertTo-Json $resp -Depth 5)"
        exit 3
    }
}
catch {
    Write-Err ("Operation failed: {0}" -f $_.Exception.Message)
    
    # Defensive error response handling
    try {
        if ($_.Exception.PSObject.Properties.Name -contains 'Response') {
            $httpResp = $_.Exception.Response
            if ($httpResp -and ($httpResp -is [System.Net.HttpWebResponse])) {
                $sr = New-Object System.IO.StreamReader($httpResp.GetResponseStream())
                $body = $sr.ReadToEnd()
                $sr.Close()
                Write-Host "Response body: $body"
            }
        }
    }
    catch {
        # Silently ignore errors when reading response body
    }
    
    exit 4
}
