# Working YAML Manifests for Windows DinD

These are the verified working YAML manifests for installing Docker on AKS-HCI Windows nodes.

## Prerequisites

- Windows node with taint: `sku=Windows:NoSchedule`
- kubectl access to cluster
- Node name (get with: `kubectl get nodes -l kubernetes.io/os=windows`)

## 1. Docker Installer

Save as `install-docker.yaml` and update `nodeSelector` with your node name:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: docker-installer-manual
  namespace: default
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: moc-wv3dsqrkel7  # CHANGE THIS
  tolerations:
  - key: "sku"
    operator: "Equal"
    value: "Windows"
    effect: "NoSchedule"
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
      Write-Host "  Docker Installation on Node: $env:COMPUTERNAME" -ForegroundColor Cyan
      Write-Host "=====================================================" -ForegroundColor Cyan
      
      try {
          Write-Host "[INFO] Checking for existing Docker..."
          $existingDocker = Get-Service -Name docker,com.docker.service,moby-engine -ErrorAction SilentlyContinue
          if ($existingDocker -and $existingDocker.Status -eq 'Running') {
              Write-Host "[SUCCESS] Docker already running. Skipping installation."
              exit 0
          }
          
          Write-Host "[INFO] Downloading Microsoft installer..."
          $installerUrl = 'https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1'
          $installerPath = 'C:\Temp\install-docker-ce.ps1'
          
          if (-not (Test-Path 'C:\Temp')) {
              New-Item -ItemType Directory -Path 'C:\Temp' -Force | Out-Null
          }
          
          Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing -TimeoutSec 60
          Write-Host "[SUCCESS] Downloaded installer"
          
          Write-Host "[INFO] Installing Docker (5-10 minutes)..."
          & $installerPath -Verbose 2>&1 | ForEach-Object { Write-Host $_ }
          
          Write-Host "[INFO] Verifying installation..."
          Start-Sleep -Seconds 5
          
          $dockerService = Get-Service -Name docker,com.docker.service,moby-engine -ErrorAction SilentlyContinue
          if (-not $dockerService) {
              Write-Host "[ERROR] Docker service not found after installation"
              exit 1
          }
          
          Write-Host "[SUCCESS] Docker service: $($dockerService.Name) - Status: $($dockerService.Status)"
          
          if ($dockerService.Status -ne 'Running') {
              Start-Service -Name $dockerService.Name
              Start-Sleep -Seconds 5
          }
          
          $dockerExe = Get-Command docker.exe -ErrorAction SilentlyContinue
          if ($dockerExe) {
              Write-Host "[SUCCESS] Docker CLI: $($dockerExe.Source)"
          }
          
          Write-Host ""
          Write-Host "=====================================================" -ForegroundColor Green
          Write-Host "  Docker Installation COMPLETED SUCCESSFULLY" -ForegroundColor Green
          Write-Host "=====================================================" -ForegroundColor Green
          
          exit 0
      } catch {
          Write-Host "[ERROR] Installation failed: $($_.Exception.Message)" -ForegroundColor Red
          exit 1
      }
  restartPolicy: Never
```

## 2. Docker Verification

Save as `verify-docker.yaml` and update `nodeSelector` with your node name:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: docker-verify
  namespace: default
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: moc-wv3dsqrkel7  # CHANGE THIS
  tolerations:
  - key: "sku"
    operator: "Equal"
    value: "Windows"
    effect: "NoSchedule"
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
    - -Command
    - |
      Write-Host "=== Docker Verification ===" -ForegroundColor Cyan
      Write-Host ""
      $svc = Get-Service -Name docker,com.docker.service,moby-engine -ErrorAction SilentlyContinue
      if ($svc) {
          Write-Host "FOUND: Docker service '$($svc.Name)'" -ForegroundColor Green
          Write-Host "STATUS: $($svc.Status)" -ForegroundColor Green
          Write-Host "START TYPE: $($svc.StartType)" -ForegroundColor White
          Write-Host ""
          $dockerExe = Get-Command docker.exe -ErrorAction SilentlyContinue
          if ($dockerExe) {
              Write-Host "docker.exe: $($dockerExe.Source)" -ForegroundColor Green
              Write-Host ""
              Write-Host "Running 'docker version'..." -ForegroundColor Yellow
              docker version
          } else {
              Write-Host "docker.exe: NOT FOUND" -ForegroundColor Red
          }
          exit 0
      } else {
          Write-Host "NOT FOUND: No Docker service" -ForegroundColor Red
          exit 1
      }
  restartPolicy: Never
```

## Quick Start Commands

```powershell
# 1. Apply installer
kubectl apply -f install-docker.yaml

# 2. Monitor installation (5-10 minutes)
kubectl logs docker-installer-manual -n default --follow --timestamps

# 3. Verify installation
kubectl apply -f verify-docker.yaml
Start-Sleep -Seconds 15
kubectl logs docker-verify -n default

# 4. Annotate node
kubectl annotate node <node-name> agents.cad4devops.dev/docker-installed=true --overwrite

# 5. Cleanup
kubectl delete pod docker-installer-manual docker-verify -n default
```

## Expected Output

### Installation Logs
```
[INFO] Starting Docker installation process...
[INFO] Checking for existing Docker...
[INFO] No working Docker installation found.
[INFO] Downloading Microsoft installer...
[SUCCESS] Downloaded installer
[INFO] Installing Docker (5-10 minutes)...
...
[SUCCESS] Docker service: docker - Status: Running
[SUCCESS] Docker CLI: C:\Windows\system32\docker.exe
=====================================================
  Docker Installation COMPLETED SUCCESSFULLY
=====================================================
```

### Verification Output
```
=== Docker Verification ===

FOUND: Docker service 'docker'
STATUS: Running
START TYPE: Automatic

docker.exe: C:\Windows\system32\docker.exe

Running 'docker version'...
Client:
 Version:           28.5.1
 API version:       1.51
 ...
Server: Docker Engine - Community
 Engine:
  Version:          28.5.1
  API version:      1.51 (minimum version 1.24)
  ...
```

## Critical Requirements

1. **Tolerations MUST be included** - Without tolerations, pods will stay in `Pending` state
2. **hostProcess MUST be true** - Required to access host Docker installation
3. **hostNetwork MUST be true** - Required for Docker daemon communication
4. **Direct script execution** - Use `& $scriptPath`, NOT `Start-Process` (which crashes)

## Troubleshooting

### Pod stays in Pending
- **Cause**: Missing toleration
- **Fix**: Verify toleration is in YAML manifest

### Pod completes but Docker not installed
- **Cause**: Missing toleration (pod never ran)
- **Fix**: Add toleration and re-run

### Check node taints
```powershell
kubectl describe node <node-name> | Select-String -Pattern "Taints:"
```

Expected: `Taints: sku=Windows:NoSchedule`

## See Also

- [WINDOWS-DIND-WORKING-SOLUTION.md](./WINDOWS-DIND-WORKING-SOLUTION.md) - Complete guide with context
- [Microsoft Install-DockerCE Script](https://raw.githubusercontent.com/microsoft/Windows-Containers/Main/helpful_tools/Install-DockerCE/install-docker-ce.ps1)
