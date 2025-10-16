# Deploy Self‑Hosted Agents Pipeline

Location: `.azuredevops/pipelines/deploy-selfhosted-agents.yml`

Purpose

- Deploys the Helm chart (or other infra) that provisions self‑hosted Azure DevOps agent pools on Kubernetes.
- Sets up the Kubernetes Deployment(s), Secrets, and (optionally) KEDA objects required to run Linux and Windows agent pools.

Note: For a single-command end-to-end onboarding (deploy infra, build **prebaked** images, and provision Azure DevOps resources) see `bootstrap-and-build.ps1`.

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
- `useOnPremAgents` (boolean, pipeline parameter): controls which CI agent pool the pipeline's summary/validation tasks run on. When true the pipeline will prefer the repository's on-prem pool name (for example `UbuntuLatestPoolOnPrem`) for jobs that must run inside your private CI environment; when false it will use the hosted `ubuntu-latest` image. The pipeline now computes an effective flag (`useOnPremAgentsEffective`) that is true whenever either `useOnPremAgents` **or** `useAzureLocal` is true, ensuring local-mode runs always target your on-prem pool.
- `azDoToken` / AZDO_PAT fallback: If the pipeline parameter for an Azure DevOps token is not explicitly provided the helper accepts the environment variable `AZDO_PAT` as a fallback.
- ACR credentials: the helper accepts `ACR_ADO_USERNAME` and `ACR_ADO_PASSWORD` from the environment. If one is supplied the other is required — the helper will fail fast on partial credential input to avoid ambiguous failures during image push/pull.
- Prebaked images: expect **no** runtime agent download; startup logs should contain `Using pre-baked Azure Pipelines agent`.
- `linuxImageVariant`: Selects which Linux image repository is referenced in the generated Helm values.
  - `dind` (default as of Oct 2025): uses the DinD-capable image repository `linux-sh-agent-dind` and the deploy helper automatically injects a `linux.dind` values block (chart 0.2.0+) enabling a privileged, root (`runAsUser: 0`) container with an in-pod Docker daemon.
  - `docker` (legacy): mounts the host / external Docker socket into the pod (no in-pod daemon). Retain only if your cluster policy forbids privileged DinD.
  - `ubuntu22` (legacy / alternate base): historical variant; not DinD‑aware. Will be phased out.
  Behavior details:
  - When `dind` is selected the script emits a `linux.dind` block with `enabled: true`, `privileged: true` and an explicit `securityContext.runAsUser=0` so docker-in-docker can start properly.
  - Weekly image refresh pipeline hard‑codes `LINUX_REPOSITORY_NAME=linux-sh-agent-dind`, ensuring rebuilt tags always include the DinD variant; no action required unless opting out.
  - To force a one-off local bootstrap build to target DinD before pipelines exist, set ` $env:LINUX_REPOSITORY_NAME='linux-sh-agent-dind' ` prior to running `bootstrap-and-build.ps1` (or let pipeline builds supply it).
  - If you accidentally pass an unexpanded literal (e.g. `'${env:ACR_NAME}'`) as registry name the Helm upgrade may fail and rollback, leaving you with the prior (non‑DinD) deployment — always verify with `helm get values` that `linux.dind.enabled` is present after deployment.

Security note (DinD): The DinD variant deliberately runs privileged and as root to launch its own `dockerd`. Apply PodSecurityPolicy / Pod Security Admission exceptions or namespace isolation accordingly. If your security posture forbids cluster‑wide privileged pods, remain on the `docker` variant (host socket mount) or supply a custom rootless image and chart patch (not provided here).

Outputs

- Helm release deployed (or Kubernetes resources applied).
- Optionally creates/updates Kubernetes Secrets for agent registration.

How it works (high level)

1. Validate environment (kubectl / helm availability and credentials). The helper performs early validation of the Azure DevOps organization URL and will attempt to pre-create required agent pools via the REST API (Ensure-Pool) when requested.
2. Render Helm chart values and inject secrets (or use existing secret store).
3. Install/upgrade Helm chart `az-selfhosted-agents` with values pointing to prebaked image tags (already containing agent bits).
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
- If startup seems slow, verify the image tag corresponds to a prebaked build and look for the log line above.
- **Agent pool creation 409 Conflict**: When creating project-scoped pools, you may encounter "Agent pool X already exists" if the pool exists at organization level. The deploy script now handles this automatically by catching the 409 error, querying to get the existing pool ID, and checking if a project queue needs to be created to link the pool to the project.
- **KEDA ScaledObject failures**: If KEDA fails with "error parsing azure Pipelines metadata: no poolName or poolID given", ensure AZDO_PAT is set so the script can query Azure DevOps API to resolve pool IDs. The Helm chart templates now conditionally render KEDA ScaledObjects only when valid poolID values are present (not empty, not placeholder values like "x" or "y").
- **PAT validation**: The deploy script performs fail-fast validation on AZDO_PAT, rejecting empty values or common placeholder strings like 'your-pat-token-here'. Check the masked PAT output in logs (shows first 4 + last 4 characters) to verify which token was resolved.
- **Helm template type errors**: If you see "error calling ne: incompatible types for comparison", this has been fixed in the ScaledObject templates which now convert poolID values to strings before comparison.
- **DinD pod fails to start dockerd**: Check container logs for the `[DinD]` lines. Ensure `linux.dind.enabled=true` produced a privileged securityContext. If `dockerd` exits repeatedly add `linux.dind.daemonArgs="--debug"` for verbose logs.
- **DinD block missing after successful Helm run**: The upgrade may have rolled back due to an earlier image name or pull error. Run `helm history <release>`; if the latest revision shows `FAILED` you are seeing the previous (non‑DinD) state. Fix the image issue (usually malformed ACR name) and redeploy.
- **`docker run hello-world` hangs**: Verify the daemon became ready (look for `[DinD] Docker daemon is ready.`). If missing, inspect `kubectl exec` into the pod and run `ps -ef | grep dockerd`.
- **Need to test image without registering agent**: Set `linux.dind.skipAgentConfig=true` (or temporarily edit values) and then exec into the pod to run Docker commands.

Notes

- For production, prefer external secret management (AKV CSI driver) instead of baking secrets into CI variables.
- The exact parameter names and steps vary per repo version — consult the pipeline YAML for precise behavior.

## Notes on pool selection

- `useAzureLocal` controls where the pipeline sources the cluster kubeconfig: when true it expects a secure-file kubeconfig (local/on-prem); when false it will attempt `az aks get-credentials` for AKS clusters.
- `useOnPremAgents` controls which pipeline pool the jobs run on (on-prem pool vs hosted images). Set `useOnPremAgents: true` when you want validation or summary tasks to run on your internal on-prem pool so they exercise the same agent environment your workloads will use.
- The deploy pipeline treats `useAzureLocal` as an implicit request for your on-prem pool. Even if `useOnPremAgents` is left false, the jobs will still run on your custom pool whenever `useAzureLocal` is true so that local clusters avoid hosted agents entirely.

Wrapper & kubeconfig selection (current behavior)

- The pipeline sets an explicit `USE_AZURE_LOCAL` environment variable and the deploy task will pass the `-UseAzureLocal` switch to the wrapper when the pipeline parameter `useAzureLocal` is true.
- The wrapper (`.azuredevops/scripts/run-deploy-selfhosted-agents-helm.ps1`) will:
  - Add `-Kubeconfig <path>` to the child deploy invocation when a `KUBECONFIG` environment variable is present (for example when the pipeline downloaded a secure-file kubeconfig or after `az aks get-credentials`).
  - Only forward the `-UseAzureLocal` switch when the explicit `USE_AZURE_LOCAL` env var is truthy. This prevents inferring local-mode from a `KUBECONFIG` value that may have been set by other steps.
  - Emit brief debug lines into the pipeline log indicating the `USE_AZURE_LOCAL` env value, `KUBECONFIG` path (if present), and whether `-UseAzureLocal` was forwarded.
- Helper selection rules:
  - If `-UseAzureLocal` is provided, helpers prefer `-KubeconfigAzureLocal` (explicit local kubeconfig filename) and fall back to `-Kubeconfig` or legacy locations only when the local file is missing.
  - If `-UseAzureLocal` is not provided, helpers prefer an explicitly provided `-Kubeconfig` (absolute or relative resolved) or the `KUBECONFIG` environment variable. If none is available they attempt to fetch AKS credentials via `az aks get-credentials` into a temporary kubeconfig (requires `az` on PATH and cluster identifiers when running in CI).
  - If no kubeconfig can be obtained the helpers fail early with a clear message to avoid operating against the wrong cluster.
