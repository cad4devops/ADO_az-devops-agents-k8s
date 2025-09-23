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

Outputs

- Sets pipeline variables or outputs indicating agent readiness and sample run status (e.g., `sampleRunId`, `sampleRunUrl`).

Troubleshooting

- If agents are not visible in the pool, verify the pod logs for registration errors and network access to `dev.azure.com`.
- Ensure the service principal / PAT used by the pipeline has permission to list pools and queue builds.
