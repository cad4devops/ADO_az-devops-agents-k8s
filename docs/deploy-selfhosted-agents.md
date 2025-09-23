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

Inputs / Parameters

- Typical parameters: cluster context, namespace, chart values file or overrides, image tag, enable/disable KEDA, pool name(s).
- The pipeline may accept boolean flags to enable Linux/Windows pools, and image tag inputs.

Outputs

- Helm release deployed (or Kubernetes resources applied).
- Optionally creates/update Kubernetes Secrets for agent registration.

How it works (high level)

1. Validate environment (kubectl / helm availability and credentials).
2. Render Helm chart values and inject secrets (or use existing secret store).
3. Install/upgrade Helm chart `az-selfhosted-agents` with provided values.
4. Optional steps to create agent pools in Azure DevOps via the REST API if desired.

Recommended usage

- Run in a secure pipeline context with access to cluster credentials only for the deployment job.
- Use a values file stored securely (do not check in populated secret values).

Troubleshooting

- If pods crash on startup, check `kubectl logs` for missing AZP_TOKEN or invalid AZP_URL.
- If Helm fails, validate chart values and permissions in the target namespace.

Notes

- For production, prefer external secret management (AKV CSI driver) instead of baking secrets into CI variables.
- The exact parameter names and steps vary per repo version — consult the pipeline YAML for precise behavior.
