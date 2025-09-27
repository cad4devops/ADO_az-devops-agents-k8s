# Run on Self‑Hosted Pool Sample Pipeline

Location: `.azuredevops/pipelines/run-on-selfhosted-pool-sample.yml`

Purpose

- A minimal sample pipeline that can be queued to verify deployed self‑hosted agent pools accept and execute jobs.
- Useful for validation/health checks after deploying agent pools.

When to run

- Manually, or automatically from a validate pipeline after agent deployment to confirm agents register and accept jobs.

What it does

- Queues a short job that runs trivial tasks (echo, tool checks) on the target pool.
- Accepts numeric parameters for hello/wait behavior so the calling validate pipeline can tune timeouts per OS.
- Optionally reports success/failure back to the calling validation job via pipeline outputs.

Parameters and usage

- `helloWaitSeconds` (number): the sample job will wait this many seconds for its hello-world pod/container to become ready. The validate pipeline forwards either `linuxHelloWaitSeconds` or `windowsHelloWaitSeconds` as appropriate.

- The calling validate pipeline forwards the OS-specific numeric wait parameter as a literal numeric value into this template to avoid shell interpolation issues in the task script.

How to adapt

- Replace sample steps with your own smoke tests (e.g., checkout + build of a tiny repo that requires the agent's tools).
- Use variable inputs to point at different pools or run reasons.

Troubleshooting

- If the pipeline remains queued, verify agent registration and that the agent pool in Azure DevOps has online agents.
- Check the agent logs for registration errors or missing permissions.
