# Windows DinD Smoke Test Failure - Root Cause and Solution

## Current Status

**Smoke test is failing with:**
```
WARNING: Docker Windows service not found (candidates: docker, moby-engine, com.docker.service).
Docker engine pipe '\\.\pipe\docker_engine' not available after service/process checks.
```

## Root Cause

The Windows agent pods were **deployed BEFORE the Docker installation step was added to the pipeline**. The agents are running but cannot access Docker because:

1. Docker Engine is not installed on the Windows nodes
2. The named pipe `\\.\pipe\docker_engine` doesn't exist
3. The smoke test expects Docker to be available for DinD scenarios

## Why This Happened

Timeline of changes:
1. ✅ Windows DinD image was built (contains Docker CLI only)
2. ✅ Agents were deployed via Helm
3. ✅ **[Today]** Added Docker installation step to deploy pipeline
4. ❌ Existing deployed agents don't have Docker on their host nodes

## Solution

### Option 1: Re-deploy (Recommended)

Re-run the deploy pipeline:
```
Pipeline: .azuredevops/pipelines/deploy-selfhosted-agents-helm.yml
Parameter: windowsImageVariant = 'dind'
```

This will:
- Execute the new "Install Docker Engine on Windows nodes (DinD requirement)" step
- Install Docker on all Windows nodes via hostProcess pods
- Validation pipeline will auto-trigger and succeed

### Option 2: Manual Installation

If you don't want to re-deploy, manually install Docker:

```powershell
cd F:\src\cad4devops\Cad4devops\ADO_az-devops-agents-k8s

.\scripts\Install-DockerOnWindowsNodes.ps1 `
  -Namespace "az-devops-windows-001" `
  -TimeoutSeconds 600 `
  -Verbose
```

Then re-run the validation pipeline.

## Verification Steps

After Docker installation, verify:

### 1. Check Docker service on nodes
```powershell
kubectl get nodes -l kubernetes.io/os=windows -o name | ForEach-Object {
  Write-Host "Checking $_"
  kubectl debug $_ -it --image=mcr.microsoft.com/powershell:lts-7.4-windowsservercore-ltsc2022 -- pwsh -Command "docker version 2>&1"
}
```

### 2. Check agent pod can see Docker
```powershell
kubectl exec -n az-devops-windows-001 -it <pod-name> -- powershell -Command "Test-Path '\\.\pipe\docker_engine'"
```

### 3. Re-run validation pipeline
The smoke test should now pass showing:
```
Docker executable detected at C:\Program Files\Docker\Docker\resources\bin\docker.exe
Docker service 'docker' status is Running
docker version
...
Docker DinD smoke test completed successfully
```

## What Changed in the Codebase

### Deploy Pipeline
- Added conditional step: "Install Docker Engine on Windows nodes (DinD requirement)"
- Runs when `parameters.windowsImageVariant == 'dind'`
- Calls `scripts/Install-DockerOnWindowsNodes.ps1`

### Helm Chart
- `windows-deploy.yaml`: Now mounts `\\.\pipe\docker_engine` instead of `/var/run/docker.sock`
- `values.yaml`: Added `windows.dind.enabled` configuration

### Deploy Script
- `deploy-selfhosted-agents-helm.ps1`: Emits `windows.dind.enabled: true` when variant is `dind`

### Smoke Test
- Enhanced diagnostics to show Docker service status
- Captures dockerd stderr for troubleshooting

## Key Learnings

### Windows DinD is Different from Linux
- **Linux**: Container runs dockerd in privileged mode
- **Windows**: Container accesses host Docker daemon via named pipe
- **Requirement**: Docker Engine must be pre-installed on Windows nodes

### Installation Uses hostProcess Pods
- Runs with `NT AUTHORITY\SYSTEM` privileges
- Can install Windows features and services
- Requires Windows Server 2022 or newer

### Pipeline Order Matters
For new deployments:
1. **Deploy pipeline** → Installs Docker on nodes
2. **Helm deployment** → Deploys agents with pipe mount
3. **Validation pipeline** → Tests Docker functionality

## Next Steps

1. **Immediate**: Re-run deploy pipeline or manually install Docker
2. **Verify**: Check Docker is running on all Windows nodes
3. **Test**: Validation pipeline should pass
4. **Document**: Update runbooks with Docker requirement for Windows DinD

## References

- Implementation doc: `docs/WINDOWS-DIND-IMPLEMENTATION.md`
- Manual install guide: `docs/MANUAL-DOCKER-INSTALL.md`
- Install script: `scripts/Install-DockerOnWindowsNodes.ps1`
- Deploy pipeline: `.azuredevops/pipelines/deploy-selfhosted-agents-helm.yml`
