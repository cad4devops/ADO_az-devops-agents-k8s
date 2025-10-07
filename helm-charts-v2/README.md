deploy:
# Helm Chart v2 — az-selfhosted-agents (v2)

This folder contains the v2 Helm chart and deployment helpers for running Azure DevOps self-hosted agents on Kubernetes. The v2 chart consolidates per-OS templates, adds better values composition, and includes tooling to generate values dynamically (for example resolving Azure DevOps numeric pool IDs for KEDA).

This README describes the chart layout, important values, deployment examples, and operational notes.

## What changed in v2

- Consolidated chart into a single chart with per-OS subcharts (linux/windows/dind) for clearer values structure.
- Built-in support for emitting Helm `values` files that include numeric `poolID` entries for KEDA ScaledObjects (helper scripts in `.azuredevops/scripts`).
- Per-OS namespaces and deterministic resource naming (recommended: `az-devops-linux-<instance>` and `az-devops-windows-<instance>`).
- Optional `WriteValuesOnly` mode in repo scripts for CI-friendly values generation and artifact publishing.
- Improved regsecret/dockerconfig handling and ACR credential wiring (pipeline wrapper fetches creds when possible).

## Layout

```text
helm-charts-v2/
  Chart.yaml
  values.yaml            # base defaults for the chart
  templates/
    _helpers.tpl
    secret.yaml
    linux-deploy.yaml
    windows-deploy.yaml
    dind-deploy.yaml
    keda-scaledobject.yaml  # optional, rendered when autoscaling.enabled=true
    namespace.yaml
    serviceaccount.yaml
    rbac.yaml
  charts/                 # if subcharts are used
  README.md               # this file
```

## Key values (high-level)

```yaml
instanceNumber: "003"         # used to derive names when not supplied
namespaces:
  linux: "az-devops-linux-003"
  windows: "az-devops-windows-003"
image:
  linux: youracr.azurecr.io/linux-sh-agent:latest
  windows: youracr.azurecr.io/windows-sh-agent:2022
acrs:
  name: ''                    # ACR name; pipeline may populate credentials
  username: ''
  password: ''
secret:
  name: sh-agent-secret-003
  data:
    AZP_URL: ''               # base64-encoded in values
    AZP_TOKEN: ''             # base64-encoded in values
    AZP_POOL_LINUX: ''        # base64
    AZP_POOL_WINDOWS: ''      # base64
deploy:
  linux: true
  windows: true
  dind: false
autoscaling:
  enabled: false
  keda:
    enabled: false
    minReplicaCount: 1
    maxReplicaCount: 5
    poolID:
      linux: ''    # numeric pool IDs inserted by helper script when possible
      windows: ''
```

## Secrets and AZP values

- The chart expects base64-encoded secret data under `secret.data`. This avoids accidental plaintext in values committed to the repo.
- The repository includes helper scripts (under `.azuredevops/scripts`) that can generate a `helm-values-override.yaml` with the proper encoded secrets and resolved `poolID` numeric values. In CI, the deploy pipeline publishes this file as an artifact.

## KEDA

- When `autoscaling.keda.enabled=true`, the `keda-scaledobject.yaml` template renders and references `.Values.autoscaling.keda.poolID.linux` / `.Values.autoscaling.keda.poolID.windows`.
- KEDA requires the numeric pool ID (not the pool name). Use the helper script to resolve pool IDs via the Azure DevOps REST API ahead of install, or supply them manually.

## Deploy examples

### Minimal (manual values)

1. Create `values.secret.yaml` locally and populate base64 secrets:

```yaml
secret:
  name: sh-agent-secret-003
  data:
    AZP_URL: "${base64 of https://dev.azure.com/yourorg}"
    AZP_TOKEN: "${base64 of PAT}"
  AZP_POOL_LINUX: "${base64 of KubernetesPoolLinux003}"
  # If you deploy with on-prem/workload cluster mode (useAzureLocal=true), use the OnPrem pool names:
  # AZP_POOL_LINUX: "${base64 of KubernetesPoolOnPremLinux003}"
```

2. Install:

```bash
helm upgrade --install az-selfhosted-agents ./helm-charts-v2 -n az-devops-linux-003 --create-namespace -f values.secret.yaml
```

### CI-driven (recommended)

- Use `.azuredevops/pipelines/deploy-selfhosted-agents-helm.yml` which:
  - downloads kubeconfig, resolves ACR credentials, and runs the repo helper script to generate `helm-values-override.yaml` (including numeric poolIDs when possible),
  - runs the helper to install KEDA and performs `helm upgrade --install` using the generated values file,
  - publishes `agent-config` artifact for downstream validation.

## Helm upgrade behavior

- Chart is designed to be idempotent; use `helm upgrade --install` to reconcile desired state.
- Uninstall via `helm uninstall <release> -n <namespace>` and consider running the repo uninstall script to optionally remove ADO pools.

## Testing locally

- You can run the helper script locally (requires PowerShell Core / pwsh) to generate values only:

```powershell
pwsh ./deploy-selfhosted-agents-helm.ps1 -InstanceNumber 003 -AzureDevOpsOrgUrl 'https://dev.azure.com/yourorg' -AzDevOpsToken '<PAT>' -WriteValuesOnly
```

- The script will emit `helm-values-override-<instance>.yaml` in the repo and, when run in CI, will copy it to `$(Build.ArtifactStagingDirectory)` for publishing.

## Operational notes

- Ensure the PAT used to resolve pool IDs has Agent Pools (Read & Manage) permissions if you want the script to create or query pools.
- If ACR admin is disabled, the pipeline's Azure CLI step will gracefully skip credential fetch; you can instead provide `acrs.username`/`acrs.password` as pipeline secrets.
- When running Windows pools, ensure Windows nodes and appropriate tolerations/taints are configured in your cluster.

## Troubleshooting

- **KEDA ScaledObject invalid poolID**: Inspect the generated `helm-values-override.yaml` artifact; it should contain numeric `poolID` fields when the resolver succeeds. The Helm templates now conditionally render ScaledObjects only when valid poolID values are present (not empty, not placeholder values).
- **KEDA "no poolName or poolID given"**: Ensure AZDO_PAT environment variable is set when running the deploy script so pool IDs can be resolved from Azure DevOps API. The deploy script now fails early if AZDO_PAT is missing or contains placeholder values like 'your-pat-token-here'.
- **Agent pool 409 Conflict**: If deployment fails with "Agent pool X already exists", the pool likely exists at organization level. The deploy script now automatically handles this by catching the 409 error, querying to get the existing pool ID, and checking if a project queue needs to be created.
- **Helm type comparison errors**: If you see "error calling ne: incompatible types for comparison", ensure you're using the latest templates which convert poolID values to strings before comparison.
- **Pod CrashLoopBackOff**: Often indicates malformed secret data (e.g., URL or token encoded incorrectly). Use `echo -n 'value' | base64` to generate values on Linux/macOS or use PowerShell `[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('value'))` on Windows.
- **PAT validation**: Check the deploy script output for masked PAT (shows first 4 + last 4 characters) to verify which token was resolved. Script rejects common placeholder values.

## Contributing

- See repository root `CONTRIBUTING.md` (or general contributing notes in root README). Submit PRs to the `helm-charts-v2` folder for improvements to templates or values.

---

If you'd like, I can also add example `values.secret.yaml` templates or a small script to create base64 encodings cross-platform.
