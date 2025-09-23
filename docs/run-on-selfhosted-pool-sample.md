# Run on Self‑Hosted Pool Sample Pipeline

Location: `.azuredevops/pipelines/run-on-selfhosted-pool-sample.yml`

Purpose

- A minimal sample pipeline that can be queued to verify deployed self‑hosted agent pools accept and execute jobs.
- Useful for validation/health checks after deploying agent pools.

When to run

- Manually, or automatically from a validate pipeline after agent deployment to confirm agents register and accept jobs.

What it does

- Queues a short job that runs trivial tasks (echo, tool checks) on the target pool.
- Optionally reports success/failure back to the calling validation job.

How to adapt

- Replace sample steps with your own smoke tests (e.g., checkout + build of a tiny repo that requires the agent's tools).
- Use variable inputs to point at different pools or run reasons.

Troubleshooting

- If the pipeline remains queued, verify agent registration and that the agent pool in Azure DevOps has online agents.
- Check the agent logs for registration errors or missing permissions.
