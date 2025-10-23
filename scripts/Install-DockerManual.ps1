# Quick Docker Installation Script for AKS Windows Nodes
# Run this manually from your local machine

Write-Host "=== Installing Docker on AKS Windows Nodes ===" -ForegroundColor Cyan

# Get Windows nodes
$windowsNodes = kubectl get nodes -l 'kubernetes.io/os=windows' -o jsonpath='{.items[*].metadata.name}'
if ([string]::IsNullOrWhiteSpace($windowsNodes)) {
    Write-Error "No Windows nodes found in the cluster"
    exit 1
}

$nodeArray = $windowsNodes -split '\s+'
Write-Host "Found $($nodeArray.Count) Windows node(s): $($nodeArray -join ', ')" -ForegroundColor Green

foreach ($nodeName in $nodeArray) {
    Write-Host "`n--- Processing node: $nodeName ---" -ForegroundColor Yellow
    
    # Create a unique job name
    $jobName = "docker-install-$(Get-Date -Format 'yyyyMMddHHmmss')-$($nodeName.ToLower() -replace '[^a-z0-9-]','')"
    
    $jobYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: $jobName
  namespace: kube-system
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: $nodeName
  tolerations:
  - key: "sku"
    operator: "Equal"
    value: "Windows"
    effect: "NoSchedule"
  containers:
  - name: installer
    image: mcr.microsoft.com/powershell:lts-7.4-windowsservercore-ltsc2022
    command:
    - C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
    - -NoLogo
    - -NoProfile
    - -ExecutionPolicy
    - Bypass
    - -Command
    args:
    - |
      `$ErrorActionPreference = 'Continue'
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      Write-Host "=== Docker Installer for Node: $nodeName ==="
      Write-Host "Checking for Docker..."
      `$svc = Get-Service docker,com.docker.service,moby-engine -ErrorAction SilentlyContinue | Select -First 1
      if (`$svc) {
          Write-Host "Docker already installed: `$(`$svc.Name)"
          exit 0
      }
      Write-Host "Installing Docker..."
      Invoke-WebRequest -UseBasicParsing https://aka.ms/moby-engine/windows2022 -OutFile C:\moby-engine.zip
      Expand-Archive -Path C:\moby-engine.zip -DestinationPath C:\ProgramData\docker -Force
      [Environment]::SetEnvironmentVariable('PATH', `$env:PATH + ';C:\ProgramData\docker', 'Machine')
      `$env:PATH += ';C:\ProgramData\docker'
      Invoke-WebRequest -UseBasicParsing https://aka.ms/moby-cli/windows2022 -OutFile C:\moby-cli.zip
      Expand-Archive -Path C:\moby-cli.zip -DestinationPath C:\ProgramData\docker -Force
      & C:\ProgramData\docker\dockerd.exe --register-service
      Start-Service docker
      Write-Host "Docker installation complete"
    securityContext:
      windowsOptions:
        hostProcess: true
        runAsUserName: "NT AUTHORITY\\SYSTEM"
  restartPolicy: Never
"@
    
    # Apply the job
    $jobYaml | kubectl apply -f -
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Installation pod created" -ForegroundColor Green
        Write-Host "  Waiting for installation to complete..." -ForegroundColor Cyan
        
        # Wait for pod to complete (max 10 minutes)
        $timeout = 600
        $elapsed = 0
        $completed = $false
        
        while ($elapsed -lt $timeout) {
            Start-Sleep -Seconds 10
            $elapsed += 10
            
            $podStatus = kubectl get pod $jobName -n kube-system -o jsonpath='{.status.phase}' 2>$null
            Write-Host "    Status: $podStatus (${elapsed}s / ${timeout}s)" -ForegroundColor Gray
            
            if ($podStatus -eq 'Succeeded') {
                $completed = $true
                Write-Host "  ✓ Docker installation completed successfully on $nodeName" -ForegroundColor Green
                break
            }
            elseif ($podStatus -eq 'Failed') {
                Write-Warning "  Installation failed on $nodeName"
                break
            }
        }
        
        # Show logs
        Write-Host "`n  Installation logs:" -ForegroundColor Cyan
        kubectl logs $jobName -n kube-system --tail=50
        
        # Cleanup
        Write-Host "`n  Cleaning up installation pod..." -ForegroundColor Gray
        kubectl delete pod $jobName -n kube-system --ignore-not-found=true
        
        if (-not $completed) {
            Write-Warning "  Installation did not complete within timeout on $nodeName"
        }
    }
    else {
        Write-Error "  Failed to create installation pod for $nodeName"
    }
}

Write-Host "`n=== Docker Installation Process Complete ===" -ForegroundColor Cyan
Write-Host "Now restart your Windows DinD agent pods:" -ForegroundColor Yellow
Write-Host "  kubectl rollout restart deployment -n az-devops-windows-002" -ForegroundColor White
