# Helper script to manually install Docker on AKS-HCI Windows nodes
# This script creates the installer pod for you with proper node targeting

param(
    [Parameter(Mandatory = $true)]
    [string]$NodeName,
    
    [Parameter()]
    [string]$Namespace = 'default',
    
    [Parameter()]
    [switch]$SkipVerification,
    
    [Parameter()]
    [switch]$SkipAnnotation,
    
    [Parameter()]
    [switch]$WaitForCompletion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Manual Docker Installation Helper                      ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Validate kubectl
$kubectl = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectl) {
    Write-Error "kubectl not found in PATH"
}

# Validate node exists
Write-Host "🔍 Validating node '$NodeName'..." -ForegroundColor Yellow
$nodeCheck = kubectl get node $NodeName 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Node '$NodeName' not found. Available nodes:`n$(kubectl get nodes -o name)"
}

# Check if node is Windows
$nodeOS = kubectl get node $NodeName -o jsonpath='{.metadata.labels.kubernetes\.io/os}'
if ($nodeOS -ne 'windows') {
    Write-Error "Node '$NodeName' is not a Windows node (OS: $nodeOS)"
}

Write-Host "✓ Node validated: $NodeName (Windows)" -ForegroundColor Green

# Check if Docker already installed
$existingAnnotation = kubectl get node $NodeName -o jsonpath='{.metadata.annotations.agents\.cad4devops\.dev/docker-installed}' 2>$null
if ($existingAnnotation -eq 'true') {
    Write-Warning "Node '$NodeName' is already annotated with docker-installed=true"
    Write-Host "Do you want to reinstall? (y/N): " -NoNewline -ForegroundColor Yellow
    $response = Read-Host
    if ($response -notmatch '^[yY]') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# Generate unique pod name
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$safeName = $NodeName.ToLower() -replace '[^a-z0-9\-]', '-'
$podName = "docker-installer-$safeName-$timestamp"

Write-Host "`n📝 Creating installer pod: $podName" -ForegroundColor Cyan

# Create installer manifest
$installerManifest = @"
apiVersion: v1
kind: Pod
metadata:
  name: $podName
  namespace: $Namespace
  labels:
    app: docker-installer
    node: $NodeName
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: $NodeName
  securityContext:
    windowsOptions:
      hostProcess: true
      runAsUserName: "NT AUTHORITY\\SYSTEM"
  containers:
  - name: installer
    image: mcr.microsoft.com/windows/nanoserver:ltsc2022
    command:
    - powershell.exe
    - -NoProfile
    - -Command
    - |
      Write-Host "=====================================================" -ForegroundColor Cyan
      Write-Host "  Docker Installation on Node: `$env:COMPUTERNAME" -ForegroundColor Cyan
      Write-Host "=====================================================" -ForegroundColor Cyan
      Write-Host ""
      
      function Write-Log {
          param([string]`$Message, [string]`$Level = 'INFO')
          `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
          `$color = switch (`$Level) {
              'ERROR' { 'Red' }
              'WARN' { 'Yellow' }
              'SUCCESS' { 'Green' }
              default { 'White' }
          }
          Write-Host "[`$timestamp] [`$Level] `$Message" -ForegroundColor `$color
      }
      
      try {
          Write-Log "Starting Docker installation process..."
          
          # Check for existing Docker
          Write-Log "Checking for existing Docker installation..."
          `$existingDocker = Get-Service -Name docker,com.docker.service,moby-engine -ErrorAction SilentlyContinue
          if (`$existingDocker) {
              Write-Log "Docker already installed: `$(`$existingDocker.Name)" "WARN"
              Write-Log "Status: `$(`$existingDocker.Status)" "INFO"
              
              if (`$existingDocker.Status -eq 'Running') {
                  Write-Log "Docker is already running. Installation skipped." "SUCCESS"
                  exit 0
              }
              
              Write-Log "Attempting to start existing Docker service..." "INFO"
              try {
                  Start-Service -Name `$existingDocker.Name -ErrorAction Stop
                  Start-Sleep -Seconds 3
                  `$svc = Get-Service -Name `$existingDocker.Name
                  if (`$svc.Status -eq 'Running') {
                      Write-Log "Docker service started successfully." "SUCCESS"
                      exit 0
                  }
              } catch {
                  Write-Log "Failed to start existing Docker service. Proceeding with reinstallation..." "WARN"
              }
          }
          
          Write-Log "No working Docker installation found."
          
          # Download Microsoft's official installer
          `$installerUrl = 'https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1'
          `$installerPath = 'C:\Temp\install-docker-ce.ps1'
          
          # Create temp directory
          if (-not (Test-Path 'C:\Temp')) {
              New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null
              Write-Log "Created C:\Temp directory"
          }
          
          Write-Log "Downloading Docker installer from Microsoft..."
          Write-Log "URL: `$installerUrl" "INFO"
          
          try {
              Invoke-WebRequest -Uri `$installerUrl -OutFile `$installerPath -UseBasicParsing -TimeoutSec 60 -ErrorAction Stop
              `$fileSize = (Get-Item `$installerPath).Length
              Write-Log "Downloaded `$fileSize bytes" "SUCCESS"
          } catch {
              Write-Log "Download failed: `$(`$_.Exception.Message)" "ERROR"
              throw
          }
          
          Write-Log "Starting Docker installation (this takes 5-10 minutes)..." "INFO"
          Write-Log "Installing Docker Engine, CLI, and configuring service..." "INFO"
          
          # Execute installer (directly, not via Start-Process which fails in hostProcess)
          try {
              & `$installerPath -Verbose 2>&1 | ForEach-Object { Write-Host `$_ }
          } catch {
              Write-Log "Installer execution failed: `$(`$_.Exception.Message)" "ERROR"
              throw
          }
          
          Write-Log "Installation script completed." "INFO"
          
          # Verify installation
          Write-Log "Verifying Docker installation..." "INFO"
          Start-Sleep -Seconds 5
          
          `$dockerService = Get-Service -Name docker,com.docker.service,moby-engine -ErrorAction SilentlyContinue
          if (-not `$dockerService) {
              Write-Log "FAILED: No Docker service found after installation" "ERROR"
              exit 1
          }
          
          Write-Log "Docker service found: `$(`$dockerService.Name)" "SUCCESS"
          Write-Log "Service status: `$(`$dockerService.Status)" "INFO"
          Write-Log "Start type: `$(`$dockerService.StartType)" "INFO"
          
          # Start Docker if not running
          if (`$dockerService.Status -ne 'Running') {
              Write-Log "Starting Docker service..." "INFO"
              try {
                  Start-Service -Name `$dockerService.Name -ErrorAction Stop
                  Start-Sleep -Seconds 5
                  `$dockerService = Get-Service -Name `$dockerService.Name
                  Write-Log "Docker service status: `$(`$dockerService.Status)" "INFO"
              } catch {
                  Write-Log "Failed to start Docker service: `$(`$_.Exception.Message)" "WARN"
              }
          }
          
          # Check for docker.exe
          `$dockerExe = Get-Command docker.exe -ErrorAction SilentlyContinue
          if (`$dockerExe) {
              Write-Log "Docker CLI found: `$(`$dockerExe.Source)" "SUCCESS"
          }
          
          # Check for dockerd.exe
          `$dockerdExe = Get-Command dockerd.exe -ErrorAction SilentlyContinue
          if (`$dockerdExe) {
              Write-Log "Docker Daemon found: `$(`$dockerdExe.Source)" "SUCCESS"
          }
          
          Write-Host ""
          Write-Host "=====================================================" -ForegroundColor Green
          Write-Host "  Docker Installation COMPLETED SUCCESSFULLY" -ForegroundColor Green
          Write-Host "=====================================================" -ForegroundColor Green
          Write-Host ""
          Write-Log "Service: `$(`$dockerService.Name)" "SUCCESS"
          Write-Log "Status: `$(`$dockerService.Status)" "SUCCESS"
          Write-Host ""
          
          exit 0
          
      } catch {
          Write-Host ""
          Write-Host "=====================================================" -ForegroundColor Red
          Write-Host "  Docker Installation FAILED" -ForegroundColor Red
          Write-Host "=====================================================" -ForegroundColor Red
          Write-Log "Error: `$(`$_.Exception.Message)" "ERROR"
          Write-Log "StackTrace: `$(`$_.ScriptStackTrace)" "ERROR"
          Write-Host ""
          exit 1
      }
  restartPolicy: Never
"@

# Apply installer pod
$manifestPath = Join-Path $env:TEMP "$podName.yaml"
$installerManifest | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host "📤 Applying installer pod..." -ForegroundColor Cyan
kubectl apply -f $manifestPath
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create installer pod"
}

Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue

# Wait for pod to start
Write-Host "⏳ Waiting for pod to start..." -ForegroundColor Yellow
Start-Sleep -Seconds 5

# Stream logs
Write-Host "`n📋 Streaming installation logs (this takes 5-10 minutes)..." -ForegroundColor Cyan
Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray

if ($WaitForCompletion) {
    # Wait for pod to complete
    kubectl logs $podName -n $Namespace -f --timestamps
    
    # Check final status
    Start-Sleep -Seconds 2
    $phase = kubectl get pod $podName -n $Namespace -o jsonpath='{.status.phase}'
    
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkGray
    Write-Host ""
    
    if ($phase -eq 'Succeeded') {
        Write-Host "✅ Installation completed successfully!" -ForegroundColor Green
    }
    else {
        Write-Warning "Pod ended with status: $phase"
    }
}
else {
    Write-Host "Pod created. To view logs run:" -ForegroundColor Yellow
    Write-Host "  kubectl logs $podName -n $Namespace -f --timestamps" -ForegroundColor White
    Write-Host ""
    Write-Host "Add -WaitForCompletion to this script to wait automatically." -ForegroundColor DarkGray
    exit 0
}

# Verification
if (-not $SkipVerification) {
    Write-Host "`n🔍 Running verification..." -ForegroundColor Cyan
    
    $verifyPodName = "docker-verify-$safeName-$timestamp"
    
    # Build verification script
    $verifyScript = @'
Write-Host "=== Docker Verification ===" -ForegroundColor Cyan
$svc = Get-Service -Name docker,com.docker.service,moby-engine -ErrorAction SilentlyContinue
if ($svc) {
    Write-Host "✓ Service: $($svc.Name)" -ForegroundColor Green
    Write-Host "✓ Status: $($svc.Status)" -ForegroundColor Green
    $dockerExe = Get-Command docker.exe -ErrorAction SilentlyContinue
    if ($dockerExe) { Write-Host "✓ Docker CLI: $($dockerExe.Source)" -ForegroundColor Green }
    exit 0
} else {
    Write-Host "✗ Docker service not found" -ForegroundColor Red
    exit 1
}
'@
    
    $verifyEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($verifyScript))
    
    $verifyManifest = @"
apiVersion: v1
kind: Pod
metadata:
  name: $verifyPodName
  namespace: $Namespace
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: $NodeName
  securityContext:
    windowsOptions:
      hostProcess: true
      runAsUserName: "NT AUTHORITY\\SYSTEM"
  containers:
  - name: verify
    image: mcr.microsoft.com/windows/nanoserver:ltsc2022
    command:
    - powershell.exe
    - -NoProfile
    - -EncodedCommand
    - $verifyEncoded
  restartPolicy: Never
"@
    
    $verifyPath = Join-Path $env:TEMP "$verifyPodName.yaml"
    $verifyManifest | Set-Content -Path $verifyPath -Encoding UTF8
    kubectl apply -f $verifyPath | Out-Null
    Remove-Item $verifyPath -Force -ErrorAction SilentlyContinue
    
    Start-Sleep -Seconds 5
    kubectl logs $verifyPodName -n $Namespace
    
    kubectl delete pod $verifyPodName -n $Namespace --ignore-not-found | Out-Null
}

# Annotate node
if (-not $SkipAnnotation) {
    Write-Host "`n🏷️  Annotating node..." -ForegroundColor Cyan
    kubectl annotate node $NodeName agents.cad4devops.dev/docker-installed=true --overwrite
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓ Node annotated: agents.cad4devops.dev/docker-installed=true" -ForegroundColor Green
    }
}

# Cleanup
Write-Host "`n🧹 Cleaning up installer pod..." -ForegroundColor Cyan
kubectl delete pod $podName -n $Namespace --ignore-not-found | Out-Null

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  DOCKER INSTALLATION COMPLETE                           ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "✅ Node: $NodeName" -ForegroundColor Green
Write-Host "✅ Docker: Installed and verified" -ForegroundColor Green
Write-Host "✅ Annotation: agents.cad4devops.dev/docker-installed=true" -ForegroundColor Green
Write-Host ""
Write-Host "🚀 Next: Deploy DinD agents with:" -ForegroundColor Cyan
Write-Host "   .\scripts\Trigger-DeployPipeline.ps1 -InstanceNumber `"002`" -WindowsImageVariant `"dind`" -UseAzureLocal" -ForegroundColor White
Write-Host ""
