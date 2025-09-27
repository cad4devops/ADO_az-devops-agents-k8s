# Welcome to Azure DevOps Self-Hosted Agents Helm Chart

Notes
-----
- This chart deploys self-hosted Azure DevOps agents and associated KEDA objects.
- By design the chart places runtime resources (agent Deployments, secrets, KEDA ScaledObjects/TriggerAuthentication) into per-OS namespaces:
    - Linux: `az-devops-linux-<instance>`
    - Windows: `az-devops-windows-<instance>`
- The Helm release itself will be installed into one of the per-OS namespaces (the deploy helper script prefers the Linux namespace when both OS deployments are enabled). The chart no longer requires a separate top-level `az-devops-<instance>` namespace to store release data.

Recommended usage (preferred)
-----------------------------
This repository includes helper PowerShell scripts that encapsulate rendering, KEDA installation and namespace management. Use them from a pipeline or locally rather than re-implementing the same logic inline.

Example (local):
```powershell
pwsh .\deploy-selfhosted-agents-helm.ps1 \
    -Kubeconfig C:\path\to\kubeconfig \
    -InstanceNumber 003 \
    -AcrName <your-acr> \
    -AcrUsername '<user>' -AcrPassword '<pw>' \
    -AzDevOpsToken '<PAT>' -AzureDevOpsOrgUrl 'https://dev.azure.com/<org>' \
    -EnsureAzDoPools
```

To uninstall (local):
```powershell
pwsh .\uninstall-selfhosted-agents-helm.ps1 -InstanceNumber 003 -Kubeconfig C:\path\to\kubeconfig
```

Pipeline authors
----------------
Use the included pipeline templates which now delegate to the same PowerShell scripts in this repo; that keeps CI logic small and consistent with local runs.

If you need to customize values directly, you can still pass Helm overrides or run `helm upgrade --install` yourself with the chart under `helm-charts-v2/az-selfhosted-agents`.