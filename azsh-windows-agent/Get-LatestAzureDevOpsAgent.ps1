# Get-LatestAzureDevOpsAgent.ps1
# Fetches the latest Azure DevOps agent version from GitHub releases

param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("windows", "linux")]
    [string]$Platform = "windows",
    
    [Parameter(Mandatory = $false)]
    [switch]$ReturnUrlOnly
)

$ErrorActionPreference = 'Stop'

function Get-LatestAgentVersion {
    param([string]$Platform)
    
    try {
        Write-Host "Fetching latest Azure DevOps Agent version from GitHub..." -ForegroundColor Cyan
        
        # Get the latest release from GitHub
        $latestRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/azure-pipelines-agent/releases/latest" -Headers @{
            "User-Agent" = "PowerShell"
        }
        
        # Extract version from tag (e.g., "v4.261.0" -> "4.261.0")
        $latestTag = $latestRelease.tag_name
        $version = $latestTag -replace '^v', ''
        
        Write-Host "Latest version: $version" -ForegroundColor Green
        
        # Construct download URL based on platform
        $platformSuffix = switch ($Platform) {
            "windows" { "win-x64" }
            "linux" { "linux-x64" }
        }
        
        $extension = if ($Platform -eq "linux") { "tar.gz" } else { "zip" }
        $downloadUrl = "https://download.agent.dev.azure.com/agent/$version/vsts-agent-$platformSuffix-$version.$extension"
        
        # Return as object
        return @{
            Version = $version
            Tag = $latestTag
            Platform = $Platform
            DownloadUrl = $downloadUrl
            PublishedAt = $latestRelease.published_at
            ReleaseUrl = $latestRelease.html_url
        }
    }
    catch {
        Write-Error "Failed to fetch latest agent version: $_"
        throw
    }
}

# Main execution
$agentInfo = Get-LatestAgentVersion -Platform $Platform

if ($ReturnUrlOnly) {
    # Just return the URL for use in scripts
    Write-Output $agentInfo.DownloadUrl
} else {
    # Display full information
    Write-Host "`nAzure DevOps Agent Information:" -ForegroundColor Yellow
    Write-Host "  Version:      $($agentInfo.Version)"
    Write-Host "  Tag:          $($agentInfo.Tag)"
    Write-Host "  Platform:     $($agentInfo.Platform)"
    Write-Host "  Published:    $($agentInfo.PublishedAt)"
    Write-Host "  Release URL:  $($agentInfo.ReleaseUrl)"
    Write-Host "  Download URL: $($agentInfo.DownloadUrl)"
    
    # Return object for pipeline use
    return $agentInfo
}
