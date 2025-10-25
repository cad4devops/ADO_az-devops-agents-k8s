#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Verifies Docker installation on Windows nodes and installs if missing.

.DESCRIPTION
    This script checks if Docker is installed on Windows nodes in the cluster
    and installs it if missing using the Install-DockerOnWindowsNodes.ps1 script.

.PARAMETER Namespace
    The namespace where Windows agents are deployed (e.g., az-devops-windows-002)

.PARAMETER Force
    Force Docker installation even if annotation suggests it's already installed

.EXAMPLE
    .\Verify-And-Install-Docker.ps1 -Namespace az-devops-windows-002
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$Namespace = 'az-devops-windows-002',
    
    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "Windows Node Docker Verification & Installation" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Check Windows nodes
Write-Host "[1/5] Checking Windows nodes..." -ForegroundColor Yellow
try {
    $windowsNodes = kubectl get nodes -l kubernetes.io/os=windows -o json | ConvertFrom-Json
    if (-not $windowsNodes.items -or $windowsNodes.items.Count -eq 0) {
        Write-Error "No Windows nodes found in the cluster"
        exit 1
    }
    
    Write-Host "Found $($windowsNodes.items.Count) Windows node(s):" -ForegroundColor Green
    foreach ($node in $windowsNodes.items) {
        Write-Host "  - $($node.metadata.name)" -ForegroundColor Gray
    }
    Write-Host ""
} catch {
    Write-Error "Failed to list Windows nodes: $_"
    exit 1
}

# Step 2: Check Docker installation annotation
Write-Host "[2/5] Checking Docker installation annotations..." -ForegroundColor Yellow
$needsInstall = $false
foreach ($node in $windowsNodes.items) {
    $nodeName = $node.metadata.name
    $dockerInstalled = $null
    
    # Safely check if annotations exist and contain docker-installed
    if ($node.metadata.annotations -and $node.metadata.annotations.PSObject.Properties.Name -contains 'docker-installed') {
        $dockerInstalled = $node.metadata.annotations.'docker-installed'
    }
    
    if ($dockerInstalled -eq 'true' -and -not $Force) {
        Write-Host "  ✓ Node '$nodeName' has docker-installed=true annotation" -ForegroundColor Green
    } else {
        if ($dockerInstalled) {
            Write-Host "  ⚠ Node '$nodeName' has docker-installed='$dockerInstalled' (not 'true')" -ForegroundColor Yellow
        } else {
            Write-Host "  ✗ Node '$nodeName' missing docker-installed annotation" -ForegroundColor Red
        }
        $needsInstall = $true
    }
}
Write-Host ""

# Step 3: Check if pods have Docker pipe mounted
Write-Host "[3/5] Checking if Windows agent pods have Docker pipe mounted..." -ForegroundColor Yellow
try {
    $deployment = kubectl get deployment -n $Namespace -l app=azsh-windows-agent -o json | ConvertFrom-Json
    if ($deployment.items -and $deployment.items.Count -gt 0) {
        $volumes = $deployment.items[0].spec.template.spec.volumes
        $dockerPipeVolume = $volumes | Where-Object { $_.name -eq 'docker-pipe' }
        
        if ($dockerPipeVolume) {
            Write-Host "  ✓ Docker pipe volume is configured in deployment" -ForegroundColor Green
            Write-Host "    Path: $($dockerPipeVolume.hostPath.path)" -ForegroundColor Gray
        } else {
            Write-Host "  ✗ Docker pipe volume NOT configured in deployment" -ForegroundColor Red
            Write-Host "    This suggests windows.dind.enabled=false in Helm values" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  ⚠ No Windows agent deployment found in namespace '$Namespace'" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  ⚠ Could not check deployment: $_" -ForegroundColor Yellow
}
Write-Host ""

# Step 4: Decide if installation is needed
if ($needsInstall -or $Force) {
    Write-Host "[4/5] Docker installation required" -ForegroundColor Yellow
    
    # Check if Install-DockerOnWindowsNodes.ps1 exists
    $scriptPath = Join-Path $PSScriptRoot 'Install-DockerOnWindowsNodes.ps1'
    if (-not (Test-Path $scriptPath)) {
        Write-Error "Install-DockerOnWindowsNodes.ps1 not found at: $scriptPath"
        exit 1
    }
    
    Write-Host "  Running: Install-DockerOnWindowsNodes.ps1 -Namespace $Namespace -TimeoutSeconds 600" -ForegroundColor Cyan
    Write-Host ""
    
    try {
        & pwsh -NoProfile -File $scriptPath -Namespace $Namespace -TimeoutSeconds 600 -Verbose
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Docker installation failed with exit code $LASTEXITCODE"
            exit 1
        }
    } catch {
        Write-Error "Docker installation failed: $_"
        exit 1
    }
    
    Write-Host ""
    Write-Host "  ✓ Docker installation completed" -ForegroundColor Green
} else {
    Write-Host "[4/5] Docker already installed (skipping installation)" -ForegroundColor Green
}
Write-Host ""

# Step 5: Verify Docker is accessible
Write-Host "[5/5] Verifying Docker is accessible on nodes..." -ForegroundColor Yellow
foreach ($node in $windowsNodes.items) {
    $nodeName = $node.metadata.name
    Write-Host "  Checking node: $nodeName" -ForegroundColor Gray
    
    # Create a debug pod to test Docker
    $testScript = @'
if (Test-Path '\\.\pipe\docker_engine') {
    Write-Host 'Docker pipe exists'
    try {
        $version = docker version --format '{{.Server.Version}}' 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Docker version: $version"
            exit 0
        } else {
            Write-Host "Docker version failed: $version"
            exit 1
        }
    } catch {
        Write-Host "Docker version error: $_"
        exit 1
    }
} else {
    Write-Host 'Docker pipe NOT found at \\.\pipe\docker_engine'
    exit 1
}
'@
    
    try {
        # Use kubectl run with hostProcess to test Docker on node
        $podName = "docker-test-$(Get-Random -Minimum 1000 -Maximum 9999)"
        
        # Create a test using the actual agent image which should have docker CLI
        $testPod = @"
apiVersion: v1
kind: Pod
metadata:
  name: $podName
  namespace: $Namespace
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/os: windows
    kubernetes.io/hostname: $nodeName
  containers:
  - name: test
    image: mcr.microsoft.com/powershell:lts-7.4-windowsservercore-ltsc2022
    command: ['pwsh', '-Command', '$testScript']
    volumeMounts:
    - mountPath: \\.\pipe\docker_engine
      name: docker-pipe
  volumes:
  - name: docker-pipe
    hostPath:
      path: \\.\pipe\docker_engine
  restartPolicy: Never
"@
        
        Write-Host "    Creating test pod..." -ForegroundColor Gray
        $testPod | kubectl apply -f - 2>&1 | Out-Null
        
        # Wait for pod to complete
        $timeout = 30
        $elapsed = 0
        while ($elapsed -lt $timeout) {
            $status = kubectl get pod $podName -n $Namespace -o jsonpath='{.status.phase}' 2>&1
            if ($status -eq 'Succeeded' -or $status -eq 'Failed') {
                break
            }
            Start-Sleep -Seconds 2
            $elapsed += 2
        }
        
        $logs = kubectl logs $podName -n $Namespace 2>&1
        kubectl delete pod $podName -n $Namespace --force --grace-period=0 2>&1 | Out-Null
        
        if ($logs -match 'Docker version:') {
            Write-Host "    ✓ Docker is accessible and working" -ForegroundColor Green
        } else {
            Write-Host "    ✗ Docker test failed:" -ForegroundColor Red
            Write-Host "      $logs" -ForegroundColor Red
        }
    } catch {
        Write-Host "    ⚠ Could not test Docker: $_" -ForegroundColor Yellow
    }
}
Write-Host ""

Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "Verification Complete" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "1. If Docker is installed but agents fail, restart agent pods:" -ForegroundColor Gray
Write-Host "   kubectl rollout restart deployment -n $Namespace azsh-windows-agent" -ForegroundColor Cyan
Write-Host ""
Write-Host "2. Run smoke test from validation pipeline:" -ForegroundColor Gray
Write-Host "   Trigger: run-on-selfhosted-pool-sample-helm.yml" -ForegroundColor Cyan
Write-Host ""
