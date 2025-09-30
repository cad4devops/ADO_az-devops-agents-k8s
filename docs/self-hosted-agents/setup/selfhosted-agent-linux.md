
# Install and configure self-hosted agents (Linux)

Use the Helm chart in this repository for most scenarios. The chart supports deploying a fleet of Linux agents, wiring secrets, and optionally enabling KEDA for queue-driven autoscaling.

Build image and push

```powershell
cd azsh-linux-agent
pwsh ./01-build-and-push.ps1 -ImageTag 2025-09-20 -Registry youracr.azurecr.io
```

Deploy with Helm

```bash
helm upgrade --install az-selfhosted-agents ./helm-charts-v2 -n az-devops --create-namespace -f values.secret.yaml
```

Run validation

After deploy, use the validation pipeline (`.azuredevops/pipelines/validate-selfhosted-agents.yml`) to confirm agents register and accept jobs. The validation pipeline can queue a sample run and waits the configured `linuxHelloWaitSeconds` (default 120) before timing out.

- Note: the validation pipeline forwards the numeric `linuxHelloWaitSeconds` parameter as a literal numeric value into the sample pipeline to avoid runtime shell interpolation issues. See `.azuredevops/pipelines/run-on-selfhosted-pool-sample-helm.yml` for details.