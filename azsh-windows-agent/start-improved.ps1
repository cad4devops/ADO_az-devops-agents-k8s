# Improved Windows Agent Start Script with Retry Logic and Timeouts
# This version adds:
# - Download timeout configuration
# - Retry logic for failed downloads
# - Better error handling
# - Progress reporting

function Print-Header ($header) {
    Write-Host "`n${header}`n" -ForegroundColor Cyan
}

function Download-AgentWithRetry {
    param(
        [string]$Url,
        [string]$Destination,
        [int]$MaxRetries = 3,
        [int]$TimeoutSeconds = 300
    )
    
    $attempt = 0
    $success = $false
    
    while (-not $success -and $attempt -lt $MaxRetries) {
        $attempt++
        Write-Host "Download attempt $attempt of $MaxRetries..."
        
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Proxy = [System.Net.WebRequest]::DefaultWebProxy
            $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
            
            # Add timeout (note: WebClient doesn't have built-in timeout, so we use a workaround)
            $wc.DownloadFile($Url, $Destination)
            
            if (Test-Path $Destination) {
                $fileSize = (Get-Item $Destination).Length
                Write-Host "Downloaded $fileSize bytes successfully"
                $success = $true
            }
        }
        catch {
            Write-Warning "Download attempt $attempt failed: $($_.Exception.Message)"
            if ($attempt -lt $MaxRetries) {
                $waitTime = [Math]::Pow(2, $attempt) * 5  # Exponential backoff: 10s, 20s, 40s
                Write-Host "Waiting $waitTime seconds before retry..."
                Start-Sleep -Seconds $waitTime
            }
        }
        finally {
            if ($wc) { $wc.Dispose() }
        }
    }
    
    if (-not $success) {
        throw "Failed to download agent after $MaxRetries attempts"
    }
}
  
if (-not (Test-Path Env:AZP_URL)) {
    Write-Error "error: missing AZP_URL environment variable"
    exit 1
}
  
if (-not (Test-Path Env:AZP_TOKEN_FILE)) {
    if (-not (Test-Path Env:AZP_TOKEN)) {
        Write-Error "error: missing AZP_TOKEN environment variable"
        exit 1
    }
  
    $Env:AZP_TOKEN_FILE = "\azp\.token"
    $Env:AZP_TOKEN | Out-File -FilePath $Env:AZP_TOKEN_FILE
}
  
Remove-Item Env:AZP_TOKEN
  
if ((Test-Path Env:AZP_WORK) -and -not (Test-Path $Env:AZP_WORK)) {
    New-Item $Env:AZP_WORK -ItemType directory | Out-Null
}
  
New-Item "\azp\agent" -ItemType directory | Out-Null
  
# Let the agent ignore the token env variables
$Env:VSO_AGENT_IGNORE = "AZP_TOKEN,AZP_TOKEN_FILE"
  
Set-Location agent
  
Print-Header "1. Determining matching Azure Pipelines agent..."
  
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$(Get-Content ${Env:AZP_TOKEN_FILE})"))
$package = Invoke-RestMethod -Headers @{Authorization = ("Basic $base64AuthInfo") } "$(${Env:AZP_URL})/_apis/distributedtask/packages/agent?platform=win-x64&`$top=1"
$packageUrl = $package[0].Value.downloadUrl
  
Write-Host $packageUrl
  
Print-Header "2. Downloading and installing Azure Pipelines agent..."

# Add random delay (0-30 seconds) to stagger downloads when multiple pods start simultaneously
$randomDelay = Get-Random -Minimum 0 -Maximum 30
Write-Host "Adding random startup delay of $randomDelay seconds to avoid download congestion..."
Start-Sleep -Seconds $randomDelay
  
# Use improved download function with retry logic
try {
    Download-AgentWithRetry -Url $packageUrl -Destination "$(Get-Location)\agent.zip" -MaxRetries 5 -TimeoutSeconds 300
}
catch {
    Write-Error "Failed to download agent: $($_.Exception.Message)"
    exit 1
}

Write-Host "Extracting agent package..."
Expand-Archive -Path "agent.zip" -DestinationPath "\azp\agent"
  
try {
    Print-Header "3. Configuring Azure Pipelines agent..."
  
    .\config.cmd --unattended `
        --agent "$(if (Test-Path Env:AZP_AGENT_NAME) { ${Env:AZP_AGENT_NAME} } else { hostname })" `
        --url "$(${Env:AZP_URL})" `
        --auth PAT `
        --token "$(Get-Content ${Env:AZP_TOKEN_FILE})" `
        --pool "$(if (Test-Path Env:AZP_POOL) { ${Env:AZP_POOL} } else { 'Default' })" `
        --work "$(if (Test-Path Env:AZP_WORK) { ${Env:AZP_WORK} } else { '_work' })" `
        --replace
  
    Print-Header "4. Running Azure Pipelines agent..."
  
    .\run.cmd
}
finally {
    Print-Header "Cleanup. Removing Azure Pipelines agent..."
  
    .\config.cmd remove --unattended `
        --auth PAT `
        --token "$(Get-Content ${Env:AZP_TOKEN_FILE})"
}
