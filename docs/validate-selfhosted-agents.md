# Validate Self‑Hosted Agents Pipeline

Location: `.azuredevops/pipelines/validate-selfhosted-agents.yml`

Purpose

- Validates that self‑hosted agent pools are properly registered and accept jobs.
- Optionally queues the sample pipeline (`run-on-selfhosted-pool-sample.yml`) and polls for completion.

When to run

- After deploying agents (automatically as part of deploy pipeline or manually) to confirm readiness.

What it does

- Uses Azure DevOps REST APIs or `az` commands to list pools and agents.
- If configured, queues the sample pipeline and waits for the run to complete, returning success/failure.
- Emits summary outputs (e.g., `sampleRunId`, `sampleRunUrl`) as pipeline outputs for downstream reporting.

Key parameters and behavior

- `linuxHelloWaitSeconds` (number, default 120): how long the Linux sample job waits for the hello-world container to become ready before the validation run continues. This value is forwarded to the sample pipeline and injected as a literal numeric value to avoid shell interpolation issues.
- `windowsHelloWaitSeconds` (number, default 180): same as above for Windows sample steps.
- `useOnPremAgents` (boolean): when true the validation jobs target the in‑repo on‑prem pool name (`UbuntuLatestPoolOnPrem` by default). When false they use hosted images like `ubuntu-latest`. The pipeline uses a template-time conditional to select the pool block.

Parallel validation

- The validation pipeline runs Linux and Windows validation streams in parallel (two jobs: `ValidateLinux` and `ValidateWindows`). Both depend only on `LoadConfig`. This shortens total validation time compared to sequential execution.

Credential handling and fallbacks

- The helper scripts and pipeline prefer an explicit kubeconfig parameter, but if not supplied they fall back to the standard locations (`$KUBECONFIG` or `~/.kube/config`) when running locally or in CI.
- If an Azure DevOps token parameter is not provided, the scripts accept the environment variable `AZDO_PAT` as a fallback for convenience.
- Container registry credentials: if either `ACR_ADO_USERNAME` or `ACR_ADO_PASSWORD` environment variables are provided, both are required. The deployment helper fails fast on partial credentials to avoid confusing authentication errors during image pull or push.

Security and output handling

- When the deploy helper or validation scripts run Helm with `--debug` they capture the full Helm output to a temporary log file. Before any publishing of that log the helper masks/redacts sensitive keys and values (for example: PAT tokens, `AZP_TOKEN`, docker auth/password fields and common secret key names such as `personalAccessToken`, `password`, `pw`, etc.). The masked artifact can be published for diagnostics without leaking secrets.

Troubleshooting

- If agents are not visible in the pool, verify the pod logs for registration errors and network access to `dev.azure.com`.
- Ensure the service principal / PAT used by the pipeline has permission to list pools and queue builds.
