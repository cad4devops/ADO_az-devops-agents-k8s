# Windows Docker-in-Docker (DinD) Complete Guide

## Overview

This guide covers Windows Docker-in-Docker (DinD) functionality for Azure DevOps self-hosted agents on Kubernetes. Windows DinD is **fully automated** and works on both **Azure AKS** and **AKS-HCI (Azure Local)**.

**Status:** ✅ Production Ready (Tested October 2025)

## Platform Support

| Platform | Status | Installation | Notes |
|----------|--------|--------------|-------|
| **Azure AKS** | ✅ Fully Supported | Automated | Windows Server 2019/2022/2025 |
| **AKS-HCI (Azure Local)** | ✅ Fully Supported | Automated | Windows Server 2019/2022/2025 |
| **Linux DinD** | ✅ Built-in | N/A | Native support, no setup needed |

## Tested Configurations

### Azure AKS
- **Kubernetes Version**: v1.32.7
- **Windows Node OS**: Windows Server 2022 Datacenter (Build 10.0.20348.4171)
- **Container Runtime**: containerd 1.7.20+azure
- **Docker Version**: 28.0.2
- **Testing Date**: October 25, 2025

### AKS-HCI (Azure Local)
- **Kubernetes Version**: v1.31.x
- **Windows Node OS**: Windows Server 2022 Datacenter
- **Container Runtime**: containerd 1.7.x
- **Docker Version**: 28.0.2
- **Testing Date**: October 25, 2025

## Architecture

### How It Works

```
┌─────────────────────────────────────────────────────────────┐
│ Kubernetes Windows Node                                      │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ containerd (Kubernetes runtime)                      │  │
│  │   - Manages Kubernetes pods                          │  │
│  │   - CSI drivers, CNI, etc.                           │  │
│  └──────────────────────────────────────────────────────┘  │
│                          │                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Docker Engine Service (28.0.2)                       │  │
│  │   - Named Pipe: \\.\pipe\docker_engine               │  │
│  │   - Used ONLY for DinD workloads                     │  │
│  │   - Auto-starts on node boot                         │  │
│  └──────────────────────────────────────────────────────┘  │
│                          │                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Azure DevOps Agent Pod (Windows)                     │  │
│  │   - Mounts: \\.\pipe\docker_engine                   │  │
│  │   - Can run: docker build, docker run, etc.          │  │
│  │   - Isolated build context per pod                   │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Key Points

1. **Dual Runtime Coexistence**: containerd (Kubernetes) and Docker Engine (DinD) run side-by-side
2. **Named Pipe Access**: Agent pods mount `\\.\pipe\docker_engine` to access Docker API
3. **No Conflicts**: Docker Engine does NOT interfere with Kubernetes operations
4. **Automated Installation**: Bootstrap script handles everything

## Automated Installation

### Using Bootstrap Script

The **recommended** method is to use the bootstrap script with the `-EnsureWindowsDocker` flag:

```powershell
# Azure AKS
pwsh -NoProfile -File .\bootstrap-and-build.ps1 `
  -InstanceNumber 003 `
  -Location canadacentral `
  -ADOCollectionName <your-org> `
  -AzureDevOpsProject <your-project> `
  -AzureDevOpsRepo <your-repo> `
  -EnableWindows `
  -EnsureWindowsDocker

# AKS-HCI (Azure Local)
pwsh -NoProfile -File .\bootstrap-and-build.ps1 `
  -UseAzureLocal `
  -InstanceNumber 002 `
  -ContainerRegistryName <your-acr> `
  -Location canadacentral `
  -ADOCollectionName <your-org> `
  -AzureDevOpsProject <your-project> `
  -AzureDevOpsRepo <your-repo> `
  -EnsureWindowsDocker
```

### What the Automation Does

1. **Detects Windows Nodes**: Queries cluster for nodes with `kubernetes.io/os=windows`
2. **Checks Existing Installation**: Skips nodes that already have Docker installed
3. **Preflight Checks**: Validates all Docker download URLs are accessible
4. **Creates HostProcess Pod**: Deploys installer pod with host access
5. **Installs Docker Engine**: 
   - Downloads Docker CLI and Engine (28.0.2)
   - Extracts to `C:\Program Files\Docker`
   - Creates and starts `docker` service
   - Configures auto-start on boot
6. **Verifies Installation**: Confirms Docker service is running
7. **Annotates Node**: Marks node as `docker-installed=true`
8. **Cleans Up**: Removes installer pod

### Manual Installation (Advanced)

If you need to install Docker manually or troubleshoot:

```powershell
# Run the standalone installer script
.\scripts\Install-DockerOnWindowsNodes.ps1 `
  -KubeConfigPath "~\.kube\config" `
  -Namespace default `
  -DockerVersion 28.0.2
```

**Options:**
- `-SkipInstallation`: Only verify existing installation
- `-TimeoutSeconds`: Adjust timeout (default: 900s)
- `-DockerVersion`: Specify Docker version (default: 28.0.2)

## Agent Configuration

### Helm Chart Values

To enable Windows DinD agents, configure your Helm values:

```yaml
# helm-charts-v2/values.yaml or custom values file

windows:
  enabled: true
  deploy:
    name: azsh-windows-agent-dind
    replicas: 2
    container:
      image: yourregistry.azurecr.io/windows-sh-agent-2022:latest
    
    # CRITICAL: Enable Docker socket mount
    volumes:
      - name: docker-pipe
        hostPath:
          path: \\.\pipe\docker_engine
          type: ""
    volumeMounts:
      - name: docker-pipe
        mountPath: \\.\pipe\docker_engine
    
    nodeSelector:
      kubernetes.io/os: windows
    
    tolerations:
      - key: "sku"
        operator: "Equal"
        value: "Windows"
        effect: "NoSchedule"
```

### Dockerfile Example

The Windows DinD images include Docker CLI:

```dockerfile
# azsh-windows-agent/Dockerfile.windows-sh-agent-2022-windows2022.prebaked
FROM mcr.microsoft.com/windows/servercore:ltsc2022

# Install tools including Docker CLI
COPY ./Install-WindowsAgentTools.ps1 C:/temp/Install-WindowsAgentTools.ps1
RUN powershell -NoProfile -ExecutionPolicy Bypass -File C:\temp\Install-WindowsAgentTools.ps1

# Agent installation
# ... (agent download and extraction)

CMD powershell .\start.ps1
```

The `Install-WindowsAgentTools.ps1` script installs Docker CLI in the image.

## Testing and Verification

### Verify Docker Installation

```powershell
# Check node annotation
kubectl get nodes -l kubernetes.io/os=windows -o json | `
  ConvertFrom-Json | `
  Select-Object -ExpandProperty items | `
  Select-Object @{Name='Node';Expression={$_.metadata.name}}, `
                @{Name='DockerInstalled';Expression={$_.metadata.annotations.'docker-installed'}}

# Expected output:
# Node              DockerInstalled
# ----              ---------------
# moc-wv3dsqrkel7   true
```

### Test DinD in Agent Pod

Create a test pipeline that runs on your Windows DinD pool:

```yaml
# .azuredevops/pipelines/test-windows-dind.yml
trigger: none

pool:
  name: YourWindowsDindPool

steps:
  - script: docker --version
    displayName: 'Check Docker Version'
  
  - script: docker info
    displayName: 'Docker Info'
  
  - script: |
      docker run --rm mcr.microsoft.com/windows/nanoserver:ltsc2022 cmd /c echo Hello from Windows container
    displayName: 'Test Container Run'
  
  - script: |
      docker build -t test:latest .
    displayName: 'Test Docker Build'
```

### Expected Test Results

✅ **Docker Version**
```
Docker version 28.0.2, build ...
```

✅ **Docker Info**
```
Server:
 Containers: 0
  Running: 0
  Paused: 0
  Stopped: 0
 Images: 1
 Server Version: 28.0.2
 Storage Driver: windowsfilter
 ...
 Operating System: Windows Server 2022 Datacenter
 OSType: windows
```

✅ **Container Run**
```
Hello from Windows container
```

## Troubleshooting

### Common Issues

#### 1. Docker Service Not Found

**Symptom:**
```
error during connect: Get "http://%2F%2F.%2Fpipe%2Fdocker_engine/_ping": ...
```

**Solution:**
- Verify Docker is installed: `kubectl get nodes -o json` (check annotations)
- Re-run installation: `.\scripts\Install-DockerOnWindowsNodes.ps1`
- Check Windows node: Access node and run `Get-Service docker`

#### 2. Named Pipe Access Denied

**Symptom:**
```
Access is denied.
```

**Solution:**
- Ensure pod has hostPath volume mount configured
- Verify pod tolerations match node taints
- Check that pod is running on node with Docker installed

#### 3. Image Pull Failures

**Symptom:**
```
Error response from daemon: pull access denied ...
```

**Solution:**
- Ensure agent has network access to image registries
- For private registries, configure `docker login` in pipeline
- Check Windows firewall rules on node

#### 4. Build Context Issues

**Symptom:**
```
unable to prepare context: path not found
```

**Solution:**
- Use explicit paths in Dockerfile: `COPY ./file.txt C:\app\`
- Ensure working directory is set correctly
- Windows uses backslashes in paths

### Debug Commands

```powershell
# Check pod logs
kubectl logs <pod-name> -n <namespace>

# Check Docker service on node (requires node access)
Get-Service docker
docker ps
docker info

# Check node events
kubectl describe node <node-name>

# Verify volume mounts in pod
kubectl describe pod <pod-name> -n <namespace>
```

### Re-installation

If you need to reinstall Docker:

```powershell
# 1. Remove annotation from node
kubectl annotate node <node-name> docker-installed-

# 2. Access the Windows node and stop/remove Docker service
# (via RDP, SSH, or host-process pod)
Stop-Service docker
sc.exe delete docker
Remove-Item -Recurse "C:\Program Files\Docker"

# 3. Re-run installation
.\scripts\Install-DockerOnWindowsNodes.ps1
```

## Performance Considerations

### Resource Requirements

**Per Windows DinD Agent Pod:**
- **CPU**: 2-4 cores recommended
- **Memory**: 4-8 GB recommended (depends on workload)
- **Disk**: 50-100 GB (for images and build cache)

**Per Windows Node:**
- **Docker Overhead**: ~200 MB RAM, minimal CPU
- **Build Caching**: Shared across pods on same node
- **Concurrent Builds**: Limited by node resources

### Scaling Recommendations

1. **Node Pool Sizing**: 
   - Small teams: 1-2 Windows nodes
   - Medium teams: 3-5 Windows nodes
   - Large teams: 5+ nodes with KEDA autoscaling

2. **Agent Replicas**:
   - Start with 1-2 replicas per node
   - Enable KEDA for dynamic scaling
   - Monitor queue depth and adjust

3. **Image Caching**:
   - Pre-pull common base images to nodes
   - Use registry mirrors for faster pulls
   - Consider node-local registry cache

## Security Best Practices

### 1. Named Pipe Access

✅ **Do:**
- Mount named pipe only in pods that need Docker
- Use separate agent pools for DinD vs non-DinD workloads
- Audit which pipelines use DinD pools

❌ **Don't:**
- Mount named pipe in all Windows pods by default
- Allow untrusted pipelines to use DinD pools
- Share DinD agent pools across teams without review

### 2. Image Security

✅ **Do:**
- Scan base images for vulnerabilities
- Use minimal base images (nanoserver vs servercore)
- Pin image versions with SHA digests
- Regularly update Docker Engine version

❌ **Don't:**
- Use `:latest` tags in production Dockerfiles
- Skip image scanning in CI/CD
- Allow pulling arbitrary public images

### 3. Network Isolation

✅ **Do:**
- Use network policies to restrict pod egress
- Configure private endpoints for registries
- Enable Azure Private Link for ACR

❌ **Don't:**
- Allow unrestricted internet access from build pods
- Disable network security groups
- Use unencrypted registry connections

### 4. Secrets Management

✅ **Do:**
- Use Azure Key Vault for sensitive values
- Mount secrets as environment variables (not files)
- Rotate Azure DevOps PATs regularly
- Use separate PATs per agent pool

❌ **Don't:**
- Commit secrets to Dockerfiles or code
- Share PATs across teams
- Use long-lived PATs without rotation

## Cost Optimization

### Azure AKS

1. **Node Pool Configuration**:
   - Use spot instances for non-critical builds
   - Right-size VMs (Standard_D4s_v3 is a good starting point)
   - Enable cluster autoscaler for Windows node pools

2. **Agent Scaling**:
   - Use KEDA to scale to zero when idle
   - Set appropriate min/max replica counts
   - Configure scale-down delays

3. **Registry**:
   - Enable geo-replication sparingly
   - Use lifecycle policies to delete old images
   - Consider Premium tier for high throughput

### AKS-HCI (Azure Local)

1. **Resource Allocation**:
   - Right-size Windows node VMs
   - Use dynamic memory allocation
   - Share nodes across workloads when possible

2. **Storage**:
   - Use local SSD storage for Docker image cache
   - Configure retention policies for build artifacts
   - Monitor disk usage on nodes

## Migration Guide

### From VM-based Agents

If migrating from VM-based self-hosted agents:

1. **Inventory Current Setup**:
   - Document installed tools and versions
   - Identify custom configurations
   - Note any host-specific dependencies

2. **Update Dockerfiles**:
   - Add required tools to `Install-WindowsAgentTools.ps1`
   - Test builds locally with Docker Desktop
   - Validate all dependencies are included

3. **Update Pipelines**:
   - Change pool names to Kubernetes-based pools
   - Test pipeline compatibility
   - Update any paths (VM paths → container paths)

4. **Gradual Migration**:
   - Run Kubernetes agents in parallel with VMs
   - Migrate low-risk pipelines first
   - Monitor for issues before full cutover
   - Decomission VMs after validation

### From Linux-only Setup

If adding Windows DinD to an existing Linux-only setup:

1. **Infrastructure**:
   - Add Windows node pool to cluster
   - Configure taints and labels
   - Install Docker on Windows nodes

2. **Helm Configuration**:
   - Enable `windows.enabled: true` in values
   - Configure separate secrets if needed
   - Deploy Windows agent release

3. **Pipeline Updates**:
   - Create Windows-specific agent pools in Azure DevOps
   - Update pipelines to target correct pools
   - Test Windows builds thoroughly

## Advanced Topics

### Custom Docker Configuration

To customize Docker daemon settings:

1. **Edit Install Script**: Modify `scripts/Install-DockerOnWindowsNodes.ps1`
2. **Add daemon.json**: Create custom Docker configuration
3. **Restart Service**: Implement service restart logic

Example custom configuration:
```json
{
  "registry-mirrors": ["https://mirror.example.com"],
  "insecure-registries": ["registry.local:5000"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
```

### Multiple Docker Versions

To support different Docker versions on different nodes:

1. Use node labels: `docker-version=28.0.2`
2. Create multiple installer variants
3. Use nodeSelector in agent deployments

### Docker-in-Docker-in-Docker (Nested)

⚠️ **Not Recommended** - Nested DinD on Windows is not supported and has severe limitations.

For complex scenarios, consider:
- Using separate agent pools
- Breaking builds into stages
- Using Azure Container Instances for nested containers

## References

### Internal Documentation
- Bootstrap Script: `docs/bootstrap-and-build.md`
- Helm Chart: `helm-charts-v2/README.md`
- Pipeline Configuration: `docs/deploy-selfhosted-agents.md`

### External Resources
- [Docker Engine on Windows](https://docs.docker.com/engine/install/)
- [Windows Containers](https://docs.microsoft.com/en-us/virtualization/windowscontainers/)
- [Kubernetes HostProcess Pods](https://kubernetes.io/docs/tasks/configure-pod-container/create-hostprocess-pod/)
- [Azure AKS Windows Containers](https://learn.microsoft.com/en-us/azure/aks/windows-container-cli)

### Docker Downloads
- Docker 28.0.2 CLI: `https://aka.ms/moby-cli/windows2022`
- Docker 28.0.2 Engine: `https://aka.ms/moby-engine/windows2022`

## Support and Troubleshooting

### Getting Help

1. **Check Logs**:
   ```powershell
   # Installer pod logs
   kubectl logs -l app=docker-installer -n default
   
   # Agent pod logs
   kubectl logs <pod-name> -n <namespace>
   ```

2. **Review Documentation**:
   - This guide
   - `copilot-instructions.md` (for automation/agents)
   - Helm chart README

3. **Open Issues**:
   - GitHub: [Issues Tracker](https://github.com/cad4devops/ADO_az-devops-agents-k8s/issues)
   - Include logs, configuration, and error messages

### Known Limitations

1. **Platform-Specific**:
   - Windows DinD only works on Windows nodes (obviously)
   - Requires Docker Engine installation (not native like Linux)
   - Named pipe access requires host path mounts

2. **Performance**:
   - Windows container startup is slower than Linux
   - First build on a node is slower (image pull)
   - Build cache is per-node, not shared

3. **Compatibility**:
   - Some Linux-based build tools may not work on Windows
   - LCOW (Linux Containers on Windows) is experimental
   - Windows containers require Windows-compatible base images

## Changelog

### October 2025
- ✅ Automated Docker installation for Azure AKS
- ✅ Automated Docker installation for AKS-HCI
- ✅ Integration with bootstrap script (`-EnsureWindowsDocker`)
- ✅ Comprehensive testing on both platforms
- ✅ Documentation consolidation

### Future Enhancements
- 🔄 LCOW support investigation
- 🔄 Docker BuildKit integration
- 🔄 Multi-architecture builds
- 🔄 Registry cache optimization

---

**Document Version**: 1.0  
**Last Updated**: October 26, 2025  
**Status**: Production Ready  
**Tested Platforms**: Azure AKS, AKS-HCI (Azure Local)
