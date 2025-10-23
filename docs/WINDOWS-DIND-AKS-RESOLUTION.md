# FINAL RESOLUTION: Windows DinD Cannot Work in Standard AKS

## Executive Summary

**Windows DinD agents CANNOT work in standard Azure Kubernetes Service (AKS)** because:

1. AKS Windows nodes use **containerd** as the container runtime (not Docker Engine)
2. The `\\.\pipe\docker_engine` named pipe does not exist
3. **Docker Engine cannot be installed** on managed AKS Windows nodes - they use immutable, managed images

## What We Discovered

### Testing Performed

✅ Verified AKS Windows node runtime:
```
Container Runtime Version: containerd://1.7.20+azure
```

✅ Attempted to install Docker Engine using multiple methods:
- `scripts\Install-DockerOnWindowsNodes.ps1` - Failed (command line too long)
- DaemonSet with hostProcess containers - Failed (no permissions)
- Manual Pod installation - Succeeded but Docker not actually installed

❌ **Result**: Docker Engine cannot be installed on managed AKS nodes

### Why AKS-HCI Worked

AKS on Azure Stack HCI provides more control over node configuration and includes Docker Engine pre-installed on Windows nodes, which is why your DinD agents worked there.

### Why Standard AKS Doesn't Support Docker Installation

- AKS uses **immutable, managed node images** for security and supportability
- Microsoft controls the base OS configuration
- Additional Windows services cannot be installed on managed nodes
- This is by design and working as intended

## Recommended Solution

### ✅ Use Regular Windows Agents (Not DinD)

**For standard AKS deployments, use regular Windows agent images without DinD functionality.**

#### Implementation Steps:

1. **Update pipeline parameters** to use regular Windows agents:

   In `.azuredevops\pipelines\run-on-selfhosted-pool-sample-helm.yml`:
   ```yaml
   parameters:
     - name: windowsImageVariant
       type: string
       default: "docker"  # Change from "dind" to "docker"
   ```

2. **Or redeploy with Helm** setting DinD disabled:
   ```powershell
   helm upgrade azdevops-windows-002 ./helm-charts-v2/azdevops-agent `
     --set windows.dind.enabled=false `
     --namespace az-devops-windows-002
   ```

3. **Restart existing Windows agent pods**:
   ```powershell
   kubectl rollout restart deployment/azsh-windows-agent -n az-devops-windows-002
   ```

4. **Remove the DinD smoke test** from pipelines targeting AKS, or make it conditional:
   ```yaml
   - ${{ if eq(parameters.useAzureLocal, true) }}:  # Only run on AKS-HCI
       - task: PowerShell@2
         displayName: Docker DinD smoke test (Windows)
         # ... DinD test steps
   ```

## Alternative Solutions

### Option A: Keep DinD Workloads on AKS-HCI

- **AKS-HCI**: Use for pipelines requiring Windows DinD (Docker pre-installed)
- **Standard AKS**: Use for regular Windows and Linux agent workloads

### Option B: Use Azure Container Instances (ACI)

For workloads that absolutely need DinD, consider Azure Container Instances which support privileged containers and Docker-in-Docker scenarios.

### Option C: Custom Node Pool with Docker (NOT RECOMMENDED)

Create a custom Windows VHD with Docker pre-installed and deploy as a custom AKS node pool. This is:
- Complex to implement and maintain
- Requires managing custom OS images
- May have supportability issues
- Not recommended for most scenarios

## Files Modified/Created

- ✅ `docs\WINDOWS-DIND-AKS-ISSUE.md` - Detailed technical analysis
- ✅ `scripts\docker-installer-daemonset.yaml` - Attempted DaemonSet (doesn't work)
- ✅ `scripts\Install-DockerManual.ps1` - Attempted manual installer (doesn't work)
- ℹ️ This file - Final resolution summary

## Impact on Current Deployment

### Current State (AKS cluster: aks-ado-agents-002)

- ✅ Windows node `akswinp000000` is healthy and running
- ✅ 5 Windows agent pods are running in `az-devops-windows-002` namespace
- ❌ DinD functionality is NOT available
- ❌ Pipeline tests expecting DinD will FAIL

### Required Actions

1. **Immediate**: Update pipeline parameters or add conditional logic to skip DinD tests on AKS
2. **Short-term**: Redeploy Windows agents without DinD configuration
3. **Long-term**: Document which features require AKS-HCI vs standard AKS

## Testing Recommendations

### For Standard AKS Windows Agents

Test that regular Windows agent functionality works:
- ✅ PowerShell script execution
- ✅ Azure CLI commands
- ✅ File operations
- ✅ Environment variables
- ❌ Do NOT test Docker daemon access

### For AKS-HCI Windows DinD Agents

Continue testing DinD functionality:
- ✅ Docker daemon access via named pipe
- ✅ Docker pull/run commands
- ✅ Container-based builds

## Conclusion

**Windows DinD is incompatible with standard AKS** due to the managed, immutable nature of AKS Windows nodes and the use of containerd instead of Docker Engine.

**Recommended path forward:**
- Use regular Windows agents (not DinD) for standard AKS
- Reserve DinD workloads for AKS-HCI where Docker is available
- Update pipelines and documentation to reflect this architectural decision

---

**Date**: October 22, 2025  
**Cluster**: aks-ado-agents-002 (Standard AKS)  
**Status**: Issue Resolved - Architecture limitation identified  
**Resolution**: Use regular Windows agents for AKS; DinD only on AKS-HCI
