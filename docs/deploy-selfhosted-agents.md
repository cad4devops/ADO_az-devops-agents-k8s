# Deploy Self‑Hosted Agents Pipeline

Location: `.azuredevops/pipelines/deploy-selfhosted-agents.yml`

Purpose

- Deploys the Helm chart (or other infra) that provisions self‑hosted Azure DevOps agent pools on Kubernetes.
- Sets up the Kubernetes Deployment(s), Secrets, and (optionally) KEDA objects required to run Linux and Windows agent pools.

When to run

- Use this pipeline to create or update the live agent pools in a Kubernetes cluster.
- Intended to be run manually or via a release flow once credentials and cluster access are configured.

Prerequisites

- `kubectl` and `helm` configured for the target cluster (cluster kubeconfig available to the service connection / agent).
- A container registry (ACR) containing agent images, or pipeline build steps that build and push images.
- Azure service connection with permissions to interact with the target subscription (if infra steps run in the pipeline).
- Secrets (AZP_URL, AZP_TOKEN, AZP_POOL) prepared (the pipeline/Helm values should reference secure values or external secret providers).

Inputs / Parameters (notable changes)

- `kubeconfig` (optional): when not supplied the deploy helper will default to `$env:KUBECONFIG` or the standard user kubeconfig at `~/.kube/config`. This makes it easier to run the helper locally without re-specifying the kubeconfig path.
- `useOnPremAgents` (boolean, pipeline parameter): controls which CI agent pool the pipeline's summary/validation tasks run on. When true the pipeline will prefer the repository's on‑prem pool name (for example `UbuntuLatestPoolOnPrem`) for jobs that must run inside your private CI environment; when false it will use the hosted `ubuntu-latest` image. This parameter is separate from `useAzureLocal` (which only controls where kubeconfig is sourced from).
- `azDoToken` / AZDO_PAT fallback: If the pipeline parameter for an Azure DevOps token is not explicitly provided the helper accepts the environment variable `AZDO_PAT` as a fallback.
- ACR credentials: the helper accepts `ACR_ADO_USERNAME` and `ACR_ADO_PASSWORD` from the environment. If one is supplied the other is required — the helper will fail fast on partial credential input to avoid ambiguous failures during image push/pull.

Outputs

- Helm release deployed (or Kubernetes resources applied).
- Optionally creates/updates Kubernetes Secrets for agent registration.

How it works (high level)

1. Validate environment (kubectl / helm availability and credentials). The helper performs early validation of the Azure DevOps organization URL and will attempt to pre-create required agent pools via the REST API (Ensure-Pool) when requested.
2. Render Helm chart values and inject secrets (or use existing secret store).
3. Install/upgrade Helm chart `az-selfhosted-agents` with provided values.
4. Optional steps to create agent pools in Azure DevOps via the REST API if desired.

Wrapper script and execution model

To avoid PowerShell parser/tokenization fragility when users run complex CLI strings in-process, the repository includes a small wrapper script that spawns a child `pwsh` process and executes the deploy helper there. This reduces accidental token leakage and makes argument parsing consistent across environments. Use the wrapper when running locally (see `azsh-linux-agent/01-build-and-push.ps1` or the top-level helper depending on the scenario).

See `copilot-instructions.md` at the repository root for additional guidance for contributors and automated agents, including safe `.tmp/` mock-run helpers for testing build/push flows without network access.

Helm output capture and masking

- When the helper runs Helm with `--debug` the full output is captured to a temporary debug log. Before any publishing or artifact upload the helper masks/redacts sensitive values such as PAT tokens, `AZP_TOKEN`, docker registry passwords, and common secret key names (for example: `personalAccessToken`, `password`, `pw`, `token`). This masked log may be published to pipelines/artifacts for diagnostics without leaking secrets.

Recommended usage

- Run in a secure pipeline context with access to cluster credentials only for the deployment job.
- Use a values file stored securely (do not check in populated secret values).

Troubleshooting

- If pods crash on startup, check `kubectl logs` for missing AZP_TOKEN or invalid AZP_URL.
- If Helm fails, validate chart values and permissions in the target namespace.

Notes

- For production, prefer external secret management (AKV CSI driver) instead of baking secrets into CI variables.
- The exact parameter names and steps vary per repo version — consult the pipeline YAML for precise behavior.

Notes on pool selection

- `useAzureLocal` controls where the pipeline sources the cluster kubeconfig: when true it expects a secure-file kubeconfig (local/on‑prem); when false it will attempt `az aks get-credentials` for AKS clusters.
- `useOnPremAgents` controls which pipeline pool the jobs run on (on‑prem pool vs hosted images). Set `useOnPremAgents: true` when you want validation or summary tasks to run on your internal on‑prem pool so they exercise the same agent environment your workloads will use.
