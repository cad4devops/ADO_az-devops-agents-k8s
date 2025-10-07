# Deployment Status - Instance 002

## ✅ Infrastructure Changes Completed

The AKS cluster has been successfully recreated with the increased Linux VM size:

### Node Configuration
| Node Pool | OS | VM Size | vCPUs | Memory | Status |
|-----------|----|---------| ------|--------|--------|
| agentpool | Linux (Ubuntu 22.04) | **Standard_D4s_v3** | **4** | 16 GB | ✅ Running |
| winp | Windows Server 2022 | Standard_D2s_v3 | 2 | 8 GB | ✅ Running |

**Note:** Linux node pool was upgraded from Standard_D2s_v3 (2 vCPUs) to Standard_D4s_v3 (4 vCPUs) to resolve KEDA pod pending issues.

### Resource Details
- **Resource Group:** `rg-aks-ado-agents-002`
- **AKS Cluster:** `aks-ado-agents-002`
- **Container Registry:** `cragents002vhu5kdbk2l7v2.azurecr.io`
- **Location:** `canadacentral`

## ⏳ Next Steps Required

### 1. Deploy Self-Hosted Agents via Pipeline

Run the Azure DevOps pipeline to install KEDA and deploy the agents:

**Pipeline:** `ADO_az-devops-agents-k8s-deploy-self-hosted-agents-helm`

**Or manually via command line:**

```powershell
# Ensure you're in the repo root
cd C:\src\MngEnvMCAP675646\AKS_agents\ADO_az-devops-agents-k8s

# Run the deployment script
pwsh -File .\deploy-selfhosted-agents-helm.ps1 `
  -InstanceNumber 002 `
  -AcrName cragents002vhu5kdbk2l7v2 `
  -AzureDevOpsOrgUrl "https://dev.azure.com/MngEnvMCAP675646" `
  -DeployLinux `
  -DeployWindows `
  -EnsureAzDoPools
```

### 2. Verify KEDA Installation

After deployment, verify KEDA pods are running:

```powershell
kubectl get pods -n keda
```

Expected output - all pods should be `Running` with `1/1` ready:
```
NAME                                               READY   STATUS    RESTARTS   AGE
keda-admission-webhooks-xxxxx                      1/1     Running   0          2m
keda-operator-xxxxx                                1/1     Running   0          2m
keda-operator-metrics-apiserver-xxxxx              1/1     Running   0          2m
```

### 3. Verify Agent Pods

Check that agent pods are running in the appropriate namespaces:

```powershell
# Check Linux agents
kubectl get pods -n az-devops-linux-002

# Check Windows agents
kubectl get pods -n az-devops-windows-002
```

### 4. Verify Node Resource Allocation

Confirm that the Linux node has sufficient free CPU:

```powershell
kubectl describe nodes | Select-String -Pattern "Name:|Allocated resources:|cpu" -Context 1
```

The Linux node should now show significantly less than 99% CPU allocation.

## 🔧 Changes Made to Fix KEDA Pending Issue

### Modified Files

1. **`infra/bicep/main.bicep`**
   - Changed default `linuxVmSize` from `'Standard_D2s_v3'` → `'Standard_D4s_v3'`
   - Added VM size options: D8s_v3, DS3_v2, DS4_v2

2. **`infra/bicep/deploy.ps1`**
   - Added `-LinuxVmSize` parameter (default: `'Standard_D4s_v3'`)
   - Added `-WindowsVmSize` parameter (default: `'Standard_D2s_v3'`)

3. **`bootstrap-and-build.ps1`**
   - Added `-LinuxVmSize` parameter (default: `'Standard_D4s_v3'`)
   - Added `-WindowsVmSize` parameter (default: `'Standard_D2s_v3'`)

### Cost Impact

| VM Size | vCPUs | Monthly Cost (approx) | Change |
|---------|-------|----------------------|---------|
| Standard_D2s_v3 | 2 | ~$70 | Previous |
| **Standard_D4s_v3** | **4** | **~$140** | **Current (+$70/mo)** |

## 📋 Troubleshooting

If KEDA pods are still pending after deployment:

1. **Check node CPU allocation:**
   ```powershell
   kubectl describe nodes aks-agentpool-33470865-vmss000000 | Select-String -Pattern "Allocated resources" -Context 5
   ```

2. **Check pod events:**
   ```powershell
   kubectl describe pods -n keda
   ```

3. **Verify node has correct size:**
   ```powershell
   kubectl get nodes -o wide
   ```

4. **Check for taints on Linux node:**
   ```powershell
   kubectl describe nodes | Select-String -Pattern "Taints:"
   ```

## 📝 Documentation

See `KEDA-FIX-SUMMARY.md` for complete details about the issue and resolution.
