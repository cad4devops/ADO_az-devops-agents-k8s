#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Triggers the deploy-selfhosted-agents-helm pipeline in Azure DevOps.

.DESCRIPTION
    This script triggers the deployment pipeline with specified parameters for
    deploying Windows DinD agents to AKS-HCI cluster.

.PARAMETER InstanceNumber
    The instance number (default: 002)

.PARAMETER WindowsImageVariant
    Windows agent variant: 'dind' or 'docker' (default: dind)

.PARAMETER UseAzureLocal
    Whether deploying to AKS-HCI (default: true)

.PARAMETER DeployLinux
    Whether to deploy Linux agents (default: true)

.PARAMETER DeployWindows
    Whether to deploy Windows agents (default: true)

.EXAMPLE
    .\Trigger-DeployPipeline.ps1 -InstanceNumber 002 -WindowsImageVariant dind -UseAzureLocal

.NOTES
    Requires AZDO_PAT environment variable to be set.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$InstanceNumber = "002",
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('dind', 'docker')]
    [string]$WindowsImageVariant = 'dind',
    
    [Parameter(Mandatory = $false)]
    [switch]$UseAzureLocal = $true,
    
    [Parameter(Mandatory = $false)]
    [switch]$DeployLinux = $true,
    
    [Parameter(Mandatory = $false)]
    [switch]$DeployWindows = $true,
    
    [Parameter(Mandatory = $false)]
    [string]$Organization = "cad4devops",
    
    [Parameter(Mandatory = $false)]
    [string]$Project = "Cad4DevOps"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "Trigger Azure DevOps Pipeline" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""

# Check for PAT
if (-not $env:AZDO_PAT) {
    Write-Error "AZDO_PAT environment variable is not set. Please set it with your Azure DevOps Personal Access Token."
    exit 1
}

$pat = $env:AZDO_PAT
$base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{
    Authorization = "Basic $base64AuthInfo"
    "Content-Type" = "application/json"
}

$orgUrl = "https://dev.azure.com/$Organization"
$pipelinesApiUrl = "$orgUrl/$Project/_apis/pipelines?api-version=7.1"

Write-Host "[1/3] Finding pipeline 'deploy-selfhosted-agents-helm'..." -ForegroundColor Yellow

try {
    $pipelinesResponse = Invoke-RestMethod -Uri $pipelinesApiUrl -Headers $headers -Method Get
    $pipeline = $pipelinesResponse.value | Where-Object { $_.name -eq "ADO_az-devops-agents-k8s-deploy-self-hosted-agents-helm" }
    
    if (-not $pipeline) {
        Write-Host "  Available pipelines:" -ForegroundColor Gray
        $pipelinesResponse.value | Select-Object -First 20 | ForEach-Object {
            Write-Host "    - $($_.name) (ID: $($_.id))" -ForegroundColor Gray
        }
        Write-Error "Pipeline 'ADO_az-devops-agents-k8s-deploy-self-hosted-agents-helm' not found."
        exit 1
    }
    
    $pipelineId = $pipeline.id
    Write-Host "  ✓ Found pipeline ID: $pipelineId" -ForegroundColor Green
    Write-Host ""
} catch {
    Write-Error "Failed to fetch pipelines: $_"
    exit 1
}

# Build parameters
Write-Host "[2/3] Preparing pipeline parameters..." -ForegroundColor Yellow
$parameters = @{
    deployLinux = $DeployLinux.IsPresent -or $DeployLinux -eq $true
    deployWindows = $DeployWindows.IsPresent -or $DeployWindows -eq $true
    windowsImageVariant = $WindowsImageVariant
    linuxImageVariant = "dind"
    useAzureLocal = $UseAzureLocal.IsPresent -or $UseAzureLocal -eq $true
    instanceNumber = $InstanceNumber
}

Write-Host "  Parameters:" -ForegroundColor Gray
$parameters.GetEnumerator() | ForEach-Object {
    Write-Host "    $($_.Key) = $($_.Value)" -ForegroundColor Gray
}
Write-Host ""

# Trigger pipeline
Write-Host "[3/3] Triggering pipeline..." -ForegroundColor Yellow

$runUrl = "$orgUrl/$Project/_apis/pipelines/$pipelineId/runs?api-version=7.1"

$body = @{
    templateParameters = $parameters
} | ConvertTo-Json -Depth 10

try {
    $runResponse = Invoke-RestMethod -Uri $runUrl -Headers $headers -Method Post -Body $body
    
    $runId = $runResponse.id
    $webUrl = $runResponse._links.web.href
    
    Write-Host "  ✓ Pipeline triggered successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Run ID: $runId" -ForegroundColor Cyan
    Write-Host "Run URL: $webUrl" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Opening pipeline in browser..." -ForegroundColor Yellow
    Start-Process $webUrl
    
} catch {
    Write-Error "Failed to trigger pipeline: $_"
    if ($_.Exception.Response) {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $reader.BaseStream.Position = 0
        $responseBody = $reader.ReadToEnd()
        Write-Host "Response: $responseBody" -ForegroundColor Red
    }
    exit 1
}

Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "Pipeline Triggered Successfully" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
