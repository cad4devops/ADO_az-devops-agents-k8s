# KEDA Pods Pending Issue - Root Cause and Fix

## Issue Summary
After deploying the self-hosted agents via the Helm pipeline, KEDA pods were stuck in Pending state:
- keda-admission-webhooks
- keda-operator  
- keda-operator-metrics-apiserver

## Root Cause
The Linux node (aks-agentpool-11210401-vmss000000) had **99% CPU allocated** (1888m out of 1900m available), leaving insufficient CPU for KEDA pods to schedule.

KEDA pods require:
- Linux nodes (nodeSelector: kubernetes.io/os=linux)
- Cannot tolerate the Windows node taint (sku=Windows:NoSchedule)

The cluster had only:
- 1 Linux node (Standard_D2s_v3 with 2 vCPUs) - nearly full
- 1 Windows node (tainted, not suitable for KEDA)

## Solution
Increased the default Linux VM size from **Standard_D2s_v3 (2 vCPUs)** to **Standard_D4s_v3 (4 vCPUs)** to ensure KEDA and agent workloads have sufficient CPU capacity.

## Files Modified

### 1. infra/bicep/main.bicep
- Changed default linuxVmSize from 'Standard_D2s_v3' to 'Standard_D4s_v3'
- Added more VM size options to the allowed list (D8s_v3, DS3_v2, DS4_v2)

### 2. infra/bicep/deploy.ps1
- Added -LinuxVmSize parameter (default: 'Standard_D4s_v3')
- Added -WindowsVmSize parameter (default: 'Standard_D2s_v3')
- Pass VM sizes to Bicep template deployment

### 3. bootstrap-and-build.ps1
- Added -LinuxVmSize parameter (default: 'Standard_D4s_v3')
- Added -WindowsVmSize parameter (default: 'Standard_D2s_v3')
- Pass VM sizes to infra/bicep/deploy.ps1

## Usage

### For new deployments:
The fix is automatic - new clusters will use Standard_D4s_v3 for Linux nodes by default.

```powershell
.\bootstrap-and-build.ps1 -InstanceNumber 003 -Location canadacentral ...
```

### For existing clusters:
You need to **scale up or recreate** the Linux node pool with the larger VM size:

```powershell
# Option 1: Delete and redeploy (easiest)
.\infra\bicep\deploy.ps1 -DeleteAksOnly -InstanceNumber 003 -Location canadacentral -RequireDeletionConfirmation -ConfirmDeletionToken "DELETE-003"
.\bootstrap-and-build.ps1 -InstanceNumber 003 -Location canadacentral ...

# Option 2: Manually scale the node pool via Azure Portal or CLI
az aks nodepool update --resource-group rg-aks-ado-agents-002 --cluster-name aks-ado-agents-002 --name agentpool --node-vm-size Standard_D4s_v3
```

### To use a custom size:
```powershell
.\bootstrap-and-build.ps1 -InstanceNumber 003 -Location canadacentral -LinuxVmSize 'Standard_D8s_v3' ...
```

## VM Size Comparison
| VM Size | vCPUs | RAM | Monthly Cost (approx) |
|---------|-------|-----|---------------------|
| Standard_D2s_v3 | 2 | 8 GB | ~ |
| Standard_D4s_v3 | 4 | 16 GB | ~ |
| Standard_D8s_v3 | 8 | 32 GB | ~ |

## Verification
After redeploying with the larger VM size, verify KEDA pods are running:
```powershell
kubectl get pods -n keda
```

All three KEDA pods should show status Running with 1/1 ready.
