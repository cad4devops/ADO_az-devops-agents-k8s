# Install Docker Engine on Windows nodes using manual installation approach
# Based on: docs\WINDOWS-DIND-AZURE-AKS-MANUAL-INSTALLATION.md
param(
    [Parameter()][string]$KubeConfigPath,
    [Parameter()][string]$Namespace = 'default',
    [Parameter()][int]$TimeoutSeconds = 900,
    [Parameter()][switch]$SkipInstallation,
    [Parameter()][string]$DockerVersion = '28.0.2'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Docker Installation for Windows Nodes                  ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Check kubectl
$kubectlCmd = Get-Command kubectl -ErrorAction SilentlyContinue
if (-not $kubectlCmd) {
    Write-Error 'kubectl not found in PATH'
}

# Build kubectl args
$kubectlArgs = @()
if ($KubeConfigPath -and (Test-Path -LiteralPath $KubeConfigPath)) {
    $kubectlArgs += '--kubeconfig'
    $kubectlArgs += $KubeConfigPath
}

# Ensure namespace exists
Write-Host "🔍 Checking namespace: $Namespace..." -ForegroundColor Yellow
$nsCheck = & kubectl @kubectlArgs get namespace $Namespace 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "📦 Creating namespace: $Namespace" -ForegroundColor Yellow
    & kubectl @kubectlArgs create namespace $Namespace 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to create namespace: $Namespace"
    }
    Write-Host "✓ Namespace created" -ForegroundColor Green
}
else {
    Write-Host "✓ Namespace exists" -ForegroundColor Green
}

# Get Windows nodes
Write-Host "🔍 Querying Windows nodes..." -ForegroundColor Yellow
$nodesJson = & kubectl @kubectlArgs get nodes -l 'kubernetes.io/os=windows' -o json 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to query Windows nodes: $nodesJson"
}

$nodeObject = $nodesJson | Out-String | ConvertFrom-Json
$items = @($nodeObject.items)
if ($items.Count -eq 0) {
    Write-Warning "No Windows nodes found"
    exit 0
}

$windowsNodes = @($items | ForEach-Object { $_.metadata.name })
Write-Host "✓ Found $($windowsNodes.Count) Windows node(s): $($windowsNodes -join ', ')" -ForegroundColor Green

$successfulNodes = @()
$failedNodes = @()

foreach ($nodeName in $windowsNodes) {
    Write-Host "`n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan
    Write-Host "  Processing node: $nodeName" -ForegroundColor Cyan
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor Cyan

    $podName = $null
    $manifestFile = $null
    
    try {
        # Generate pod name
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $safeName = $nodeName.ToLower() -replace '[^a-z0-9\-]', '-'
        $podName = "docker-installer-$safeName-$timestamp"

        # Check if Docker already installed
        Write-Host "📋 Checking if Docker is already installed..." -ForegroundColor Yellow
        $checkResult = & kubectl @kubectlArgs get node $nodeName -o jsonpath='{.metadata.annotations.agents\.cad4devops\.dev/docker-installed}' 2>$null
        
        if ($checkResult -eq 'true' -and -not $SkipInstallation) {
            Write-Host "ℹ️  Node already annotated with docker-installed=true" -ForegroundColor Yellow
            Write-Host "   Verifying Docker is actually running..." -ForegroundColor Yellow
        }

        # Create installer pod manifest
        $manifest = @"
apiVersion: v1
kind: Pod
metadata:
  name: $podName
  namespace: $Namespace
  labels:
    app: docker-installer
    node: $nodeName
spec:
  hostNetwork: true
  nodeSelector:
    kubernetes.io/hostname: $nodeName
  tolerations:
  - effect: NoSchedule
    key: sku
    value: Windows
  containers:
  - name: installer
    image: mcr.microsoft.com/windows/nanoserver:ltsc2022
    command:
    - powershell.exe
    - -Command
    - "while(`$true){Start-Sleep 60}"
    securityContext:
      windowsOptions:
        hostProcess: true
        runAsUserName: "NT AUTHORITY\\SYSTEM"
  restartPolicy: Never
"@

        # Save manifest to temp file
        $manifestFile = [System.IO.Path]::GetTempFileName()
        $manifest | Out-File -FilePath $manifestFile -Encoding utf8 -Force
        
        # Create pod
        Write-Host "📦 Creating installer pod: $podName" -ForegroundColor Yellow
        $createOutput = & kubectl @kubectlArgs apply -f $manifestFile 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create pod: $createOutput"
        }

        # Wait for pod to be running
        Write-Host "⏳ Waiting for pod to start (timeout: ${TimeoutSeconds}s)..." -ForegroundColor Yellow
        $elapsed = 0
        $interval = 5
        $podReady = $false
        
        while ($elapsed -lt $TimeoutSeconds) {
            $podStatus = & kubectl @kubectlArgs get pod $podName -n $Namespace -o jsonpath='{.status.phase}' 2>$null
            if ($podStatus -eq 'Running') {
                $podReady = $true
                Write-Host "✓ Pod is running" -ForegroundColor Green
                Start-Sleep -Seconds 3  # Give it a moment to stabilize
                break
            }
            Start-Sleep -Seconds $interval
            $elapsed += $interval
            Write-Host "   Still waiting... ($elapsed s)" -ForegroundColor Gray
        }

        if (-not $podReady) {
            throw "Pod did not reach Running state within ${TimeoutSeconds}s"
        }

        # Check if Docker service already exists and is running
        Write-Host "`n📋 Step 1: Check existing Docker service..." -ForegroundColor Cyan
        $serviceCheck = & kubectl @kubectlArgs exec $podName -n $Namespace -- powershell.exe -Command "Get-Service docker -ErrorAction SilentlyContinue | Select-Object Name,Status,StartType | ConvertTo-Json -Compress" 2>$null
        
        $dockerAlreadyInstalled = $false
        if ($LASTEXITCODE -eq 0 -and $serviceCheck) {
            try {
                $service = $serviceCheck | ConvertFrom-Json
                $dockerAlreadyInstalled = $true
                
                if ($service.Status -eq 'Running') {
                    Write-Host "✓ Docker service already running!" -ForegroundColor Green
                    Write-Host "   Name: $($service.Name), Status: $($service.Status), StartType: $($service.StartType)" -ForegroundColor Gray
                    
                    # Verify version
                    Write-Host "`n📋 Verifying Docker version..." -ForegroundColor Cyan
                    & kubectl @kubectlArgs exec $podName -n $Namespace -- powershell.exe -Command "docker version --format '{{.Server.Version}}'" 2>&1 | Write-Host
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "✓ Docker is fully functional on $nodeName" -ForegroundColor Green
                        
                        # Annotate node
                        Write-Host "`n📝 Annotating node..." -ForegroundColor Yellow
                        & kubectl @kubectlArgs annotate node $nodeName agents.cad4devops.dev/docker-installed=true --overwrite 2>&1 | Out-Null
                        
                        $successfulNodes += $nodeName
                        continue
                    }
                }
                else {
                    Write-Host "⚠️  Docker service exists but not running (Status: $($service.Status))" -ForegroundColor Yellow
                    Write-Host "   Will attempt to start existing Docker service instead of reinstalling..." -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "ℹ️  Could not parse service check output" -ForegroundColor Gray
            }
        }
        else {
            Write-Host "ℹ️  Docker service not found (will install)" -ForegroundColor Gray
        }
        
        # If Docker is already installed but stopped, skip to service start step
        if ($dockerAlreadyInstalled) {
            Write-Host "`n⏩ Skipping installation steps (Docker binaries already present)" -ForegroundColor Cyan
            Write-Host "   Jumping to Step 7: Start Docker service..." -ForegroundColor Cyan
        }

        if ($SkipInstallation) {
            Write-Warning "SkipInstallation flag set - not installing Docker"
            continue
        }

        # Only run installation steps if Docker is not already installed
        if (-not $dockerAlreadyInstalled) {
            # Step 2: Download Docker
            Write-Host "`n📥 Step 2: Downloading Docker $DockerVersion..." -ForegroundColor Cyan
            $downloadCmd = "Write-Host 'Downloading Docker ${DockerVersion}...'; Invoke-WebRequest -Uri 'https://download.docker.com/win/static/stable/x86_64/docker-${DockerVersion}.zip' -OutFile 'C:\docker.zip' -UseBasicParsing; Write-Host 'Download complete'; (Get-Item C:\docker.zip).Length"
            
            $downloadOutput = & kubectl @kubectlArgs exec $podName -n $Namespace -- powershell.exe -Command $downloadCmd 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to download Docker: $downloadOutput"
            }
            Write-Host $downloadOutput
            Write-Host "✓ Docker archive downloaded" -ForegroundColor Green

            # Step 3: Extract Docker
            Write-Host "`n📂 Step 3: Extracting Docker archive..." -ForegroundColor Cyan
            $extractCmd = "Expand-Archive -Path C:\docker.zip -DestinationPath C:\ProgramFiles -Force; Test-Path C:\ProgramFiles\docker\dockerd.exe"
            
            $extractOutput = & kubectl @kubectlArgs exec $podName -n $Namespace -- powershell.exe -Command $extractCmd 2>&1
            if ($LASTEXITCODE -ne 0 -or $extractOutput -ne 'True') {
                throw "Failed to extract Docker: $extractOutput"
            }
            Write-Host "✓ Docker extracted to C:\ProgramFiles\docker" -ForegroundColor Green

            # Step 4: Add to PATH
            Write-Host "`n🔧 Step 4: Adding Docker to system PATH..." -ForegroundColor Cyan
            $pathCmd = "[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path','Machine') + ';C:\ProgramFiles\docker', 'Machine'); Write-Host 'PATH updated'"
            
            $pathOutput = & kubectl @kubectlArgs exec $podName -n $Namespace -- powershell.exe -Command $pathCmd 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to update PATH: $pathOutput"
            }
            Write-Host "✓ PATH updated" -ForegroundColor Green

            # Step 5: Verify binary
            Write-Host "`n🔍 Step 5: Verifying Docker binary..." -ForegroundColor Cyan
            $versionCmd = "C:\ProgramFiles\docker\dockerd.exe --version"
            
            $versionOutput = & kubectl @kubectlArgs exec $podName -n $Namespace -- powershell.exe -Command $versionCmd 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to verify Docker binary: $versionOutput"
            }
            Write-Host $versionOutput
            Write-Host "✓ Docker binary verified" -ForegroundColor Green

            # Step 6: Register service
            Write-Host "`n⚙️  Step 6: Registering Docker as Windows service..." -ForegroundColor Cyan
            $registerCmd = "C:\ProgramFiles\docker\dockerd.exe --register-service; Write-Host 'Docker service registered'"
            
            $registerOutput = & kubectl @kubectlArgs exec $podName -n $Namespace -- powershell.exe -Command $registerCmd 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to register Docker service: $registerOutput"
            }
            Write-Host "✓ Docker service registered" -ForegroundColor Green
        }

        # Step 7: Start service
        Write-Host "`n🚀 Step 7: Starting Docker service..." -ForegroundColor Cyan
        $startCmd = "Start-Service docker; Start-Sleep -Seconds 3; Get-Service docker | Select-Object Name,Status,StartType | ConvertTo-Json -Compress"
        
        $startOutput = & kubectl @kubectlArgs exec $podName -n $Namespace -- powershell.exe -Command $startCmd 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to start Docker service: $startOutput"
        }
        
        try {
            $serviceInfo = $startOutput | ConvertFrom-Json
            Write-Host "✓ Docker service started:" -ForegroundColor Green
            Write-Host "   Name: $($serviceInfo.Name)" -ForegroundColor Gray
            Write-Host "   Status: $($serviceInfo.Status) (1=Stopped, 4=Running)" -ForegroundColor Gray
            Write-Host "   StartType: $($serviceInfo.StartType) (2=Automatic, 3=Manual)" -ForegroundColor Gray
        }
        catch {
            Write-Host $startOutput
        }

        # Step 8: Verify client connection
        Write-Host "`n✅ Step 8: Verifying Docker client connection..." -ForegroundColor Cyan
        $dockerCmd = "C:\ProgramFiles\docker\docker.exe version --format '{{.Client.Version}} / {{.Server.Version}}'"
        
        $dockerOutput = & kubectl @kubectlArgs exec $podName -n $Namespace -- powershell.exe -Command $dockerCmd 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Docker client verification failed: $dockerOutput"
        }
        else {
            Write-Host "✓ Docker client/server: $dockerOutput" -ForegroundColor Green
        }

        # Step 9: Verify named pipe
        Write-Host "`n🔌 Step 9: Verifying Docker named pipe..." -ForegroundColor Cyan
        $pipeCmd = "Test-Path '\\.\pipe\docker_engine'"
        
        $pipeOutput = & kubectl @kubectlArgs exec $podName -n $Namespace -- powershell.exe -Command $pipeCmd 2>&1
        if ($pipeOutput -eq 'True') {
            Write-Host "✓ Named pipe exists: \\.\pipe\docker_engine" -ForegroundColor Green
        }
        else {
            Write-Warning "Named pipe not found (may appear after a moment)"
        }

        # Annotate node as having Docker installed
        Write-Host "`n📝 Annotating node with docker-installed=true..." -ForegroundColor Yellow
        & kubectl @kubectlArgs annotate node $nodeName agents.cad4devops.dev/docker-installed=true --overwrite 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✓ Node annotated" -ForegroundColor Green
        }

        Write-Host "`n🎉 Docker installation completed successfully on $nodeName!" -ForegroundColor Green
        $successfulNodes += $nodeName

    }
    catch {
        Write-Host "`n❌ ERROR processing node ${nodeName}: $_" -ForegroundColor Red
        $failedNodes += $nodeName
        
        # Try to get pod logs if pod exists
        if ($podName) {
            Write-Host "`n📋 Pod logs:" -ForegroundColor Yellow
            & kubectl @kubectlArgs logs $podName -n $Namespace --tail=50 2>&1 | Write-Host
            
            Write-Host "`n📋 Pod description:" -ForegroundColor Yellow
            & kubectl @kubectlArgs describe pod $podName -n $Namespace 2>&1 | Write-Host
        }
    }
    finally {
        # Cleanup pod
        if ($podName) {
            Write-Host "`n🧹 Cleaning up installer pod..." -ForegroundColor Yellow
            & kubectl @kubectlArgs delete pod $podName -n $Namespace --ignore-not-found=true 2>&1 | Out-Null
        }
        
        # Cleanup manifest file
        if ($manifestFile -and (Test-Path $manifestFile)) {
            Remove-Item -LiteralPath $manifestFile -Force -ErrorAction SilentlyContinue
        }
    }
}

# Summary
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  Installation Summary                                    ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

if ($successfulNodes.Count -gt 0) {
    Write-Host "✅ Successfully configured $($successfulNodes.Count) node(s):" -ForegroundColor Green
    $successfulNodes | ForEach-Object { Write-Host "   - $_" -ForegroundColor Green }
}

if ($failedNodes.Count -gt 0) {
    Write-Host "`n❌ Failed to configure $($failedNodes.Count) node(s):" -ForegroundColor Red
    $failedNodes | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
    Write-Error "Docker installation failed on one or more nodes"
}

if ($successfulNodes.Count -eq 0) {
    Write-Error "Docker installation failed: no nodes were processed successfully"
}

Write-Host "`n✓ Installation process complete" -ForegroundColor Green
