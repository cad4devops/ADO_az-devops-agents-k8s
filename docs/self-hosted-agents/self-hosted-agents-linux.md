
# Linux self-hosted agents (Kubernetes)

This document explains the recommended way to run Azure DevOps self‑hosted agents on Kubernetes using the Helm charts in this repository. If you want to manually install a single agent on a VM, the old manual steps are included in the appendix.

Recommended: Helm chart (v2)

- Chart: `helm-charts-v2/az-selfhosted-agents` (recommended). The v2 chart contains per-OS subcharts and improved values composition.
- Quick install (example):

```bash
helm upgrade --install az-selfhosted-agents ./helm-charts-v2 -n az-devops --create-namespace -f values.secret.yaml
```

Important values and secrets

- `secret.data.AZP_URL`, `AZP_TOKEN`, `AZP_POOL`: required to register agents. Values are base64-encoded in `values.secret.yaml` by convention.
- `linux.enabled`: enable/disable the Linux pool.
- `linux.deploy.replicas`: desired replica count for the Linux agent Deployment.
- `autoscaling.keda.enabled`: enable KEDA ScaledObject if you want queue-driven scaling.

Local helper and wrapper

- The repository includes a PowerShell deploy helper that runs Helm and performs preflight checks. The helper accepts a `-Kubeconfig` parameter but will fall back to `$env:KUBECONFIG` or `~/.kube/config` when not supplied.
- To avoid PowerShell parser fragility, use the included wrapper script which spawns a child `pwsh` process to run the helper. This is the recommended way to run the helper locally.

- The helper also accepts Azure DevOps PAT via the `AZDO_PAT` environment variable as a convenience fallback when an explicit parameter is not provided. When supplying container registry credentials via environment variables `ACR_ADO_USERNAME` / `ACR_ADO_PASSWORD`, both must be present or the helper will fail early.

- If Helm `--debug` is used during deploy, the helper captures the debug output to a temporary file and masks common secret keys/values before any artifact publishing so logs can be shared safely.

Registry credentials

- If you provide container registry credentials via `ACR_ADO_USERNAME` / `ACR_ADO_PASSWORD` they must both be supplied. The helper fails fast on partial input to avoid ambiguous failures.

Validation and sample runs

- The repository provides a validation pipeline (`.azuredevops/pipelines/validate-selfhosted-agents.yml`) which queues a sample pipeline to exercise the pool. The validation pipeline exposes parameters for `linuxHelloWaitSeconds` (default 120) which control how long the sample waits for the hello pod.

Troubleshooting

- Check `kubectl logs <pod>` in the target namespace for registration errors.
- Verify the secret contains the correct base64-encoded `AZP_TOKEN` and `AZP_URL`.

Appendix: manual agent install (legacy)

If you need to register a single Linux VM agent manually, follow the classic steps:

```bash
mkdir myagent && cd myagent
wget https://vstsagentpackage.azureedge.net/agent/2.214.1/vsts-agent-linux-x64-2.214.1.tar.gz
tar zxvf vsts-agent-linux-x64-2.214.1.tar.gz
./config.sh
# follow prompts: URL, PAT, pool, name
sudo ./svc.sh install
sudo ./svc.sh start
```


