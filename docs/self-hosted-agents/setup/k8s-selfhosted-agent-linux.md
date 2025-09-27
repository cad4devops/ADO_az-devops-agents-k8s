
# Build and deploy self-hosted agents to Kubernetes (Linux)

This page documents building the Linux agent image and deploying it using the Helm chart.

Build image (example)

```powershell
cd azsh-linux-agent
pwsh ./01-build-and-push.ps1 -ImageTag 2025-09-20 -Registry youracr.azurecr.io
```

Deploy with Helm

```bash
helm upgrade --install az-selfhosted-agents ./helm-charts-v2 -n az-devops --create-namespace -f values.secret.yaml
```

Notes

- The repository includes helper scripts to build and push images and to render Helm values. The deploy helper will use `ACR_ADO_USERNAME` and `ACR_ADO_PASSWORD` from the environment when performing authenticated pushes/pulls.

- If using environment credential fallbacks, both `ACR_ADO_USERNAME` and `ACR_ADO_PASSWORD` must be present or the helper will fail early. When Helm `--debug` is used the helper captures debug output and masks likely secrets before any artifact publishing.


