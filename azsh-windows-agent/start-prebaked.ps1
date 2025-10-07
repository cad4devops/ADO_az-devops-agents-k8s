# Start script for pre-baked Azure Pipelines agent
# This version assumes the agent is already downloaded and extracted in the image
# at /azp/agent, so it skips the download step entirely.

function Print-Header ($header) {
    Write-Host "`n${header}`n" -ForegroundColor Cyan
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

# Let the agent ignore the token env variables
$Env:VSO_AGENT_IGNORE = "AZP_TOKEN,AZP_TOKEN_FILE"

# Check if agent is already pre-baked in the image
$agentPath = "\azp\agent"
$configScript = Join-Path $agentPath "config.cmd"

if (Test-Path $configScript) {
    Print-Header "Using pre-baked Azure Pipelines agent (no download required)"
    Set-Location $agentPath
} else {
    # Fallback: Download agent if not pre-baked (backward compatibility)
    Print-Header "1. Determining matching Azure Pipelines agent..."
    
    New-Item "\azp\agent" -ItemType directory | Out-Null
    Set-Location agent
    
    $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$(Get-Content ${Env:AZP_TOKEN_FILE})"))
    $package = Invoke-RestMethod -Headers @{Authorization = ("Basic $base64AuthInfo") } "$(${Env:AZP_URL})/_apis/distributedtask/packages/agent?platform=win-x64&`$top=1"
    $packageUrl = $package[0].Value.downloadUrl
    
    Write-Host $packageUrl
    
    Print-Header "2. Downloading and installing Azure Pipelines agent..."
    
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($packageUrl, "$(Get-Location)\agent.zip")
    
    Expand-Archive -Path "agent.zip" -DestinationPath "\azp\agent"
}

try {
    Print-Header "Configuring Azure Pipelines agent..."
  
    .\config.cmd --unattended `
        --agent "$(if (Test-Path Env:AZP_AGENT_NAME) { ${Env:AZP_AGENT_NAME} } else { hostname })" `
        --url "$(${Env:AZP_URL})" `
        --auth PAT `
        --token "$(Get-Content ${Env:AZP_TOKEN_FILE})" `
        --pool "$(if (Test-Path Env:AZP_POOL) { ${Env:AZP_POOL} } else { 'Default' })" `
        --work "$(if (Test-Path Env:AZP_WORK) { ${Env:AZP_WORK} } else { '_work' })" `
        --replace
  
    Print-Header "Running Azure Pipelines agent..."
  
    .\run.cmd
}
finally {
    Print-Header "Cleanup. Removing Azure Pipelines agent..."
  
    .\config.cmd remove --unattended `
        --auth PAT `
        --token "$(Get-Content ${Env:AZP_TOKEN_FILE})"
}
