# Workload Identity Federation Automation Changes

This document summarizes the incremental changes made to `bootstrap-and-build.ps1` to automate and harden Azure DevOps Workload Identity Federation (WIF) service connection creation and federated credential provisioning.

## Earlier Structural Refactor (Initial Wave)

- Moved WIF service connection creation before image builds (fail-fast ordering).
- Introduced success flag (`$wifCreationSucceeded`) and abort logic if creation/validation fails.
- Removed legacy/duplicate WIF creation block to avoid double attempts.
- Added automatic Entra application & service principal creation when `-CreateServicePrincipal` or no client id supplied.
- Added default issuer and deferred subject computation model (`$deferFederatedSubject`).

## Diagnostic & Resilience Enhancements (Middle Wave)

- Implemented custom `Invoke-DevOpsJson` HttpClient helper to capture raw bodies on non-2xx responses.
- Parsed JSON error payloads to surface: message, typeName, errorCode.
- Added contextual hints (permissions, approvals pending, propagation, feature enablement).
- Implemented dynamic payload self-heal: remove unexpected fields flagged by API and retry.
- Removed problematic / rejected fields (`scope`) and generalized removal across `authorization.parameters`, `data`, and root.
- Added richer payload fields (owner, isShared, creationMode, scopeLevel) while still pruning when rejected.
- Introduced resilient project id retrieval (CLI -> configure defaults -> REST fallback).
- Added fallback API version (7.1 then 7.0) for service endpoint creation.

## Federated Credential Reliability (Late Wave)

- Added exponential backoff retry loop for federated credential creation with transient error detection.
- Implemented CLI evolution handling: fallback to `--parameters` JSON file when direct argument form rejected.
- Surfaced permission / insufficient privilege messages early and aborted retries accordingly.

## Duplicate Service Connection Handling

- Initial handling: treated HTTP 409 DuplicateServiceConnection as a hard failure.
- Enhanced logic: on 409, attempt `az devops service-endpoint list` to locate existing SC by name and confirm WIF scheme.
- Added `-ProceedOnDuplicateNoVisibility` to continue when SC exists but PAT cannot list it (e.g., lacks visibility permissions) instead of failing fast.
- Added `-ExistingServiceConnectionId` to supply known SC id so that the federated credential subject can still be computed when visibility is lacking.

## Additional Hardening

- Added `-AutoRepairAzDevOpsExtension` to detect and repair a corrupt/inaccessible `azure-devops` CLI extension (remove + reinstall pattern).
- Added guard to skip federated credential ensure when proceeding without a computable subject.
- Cleaned up parser errors (removed accidental duplicated footer/concatenated statements).
- Renamed helper function from non-approved verb (`Post-DevOpsJson`) to `Invoke-DevOpsJson` and removed unused variables.

## New / Adjusted Parameters

| Parameter | Purpose |
|-----------|---------|
| `-CreateWifServiceConnection` | Enables WIF service connection ensure phase (early fail-fast). |
| `-CreateServicePrincipal` | Ensures Entra application & service principal exist. Auto-enabled if no client id. |
| `-FederatedIssuer` | Explicit issuer override (legacy default `https://vstoken.dev.azure.com/{org}` when `-UseAadIssuer` not specified). |
| `-UseAadIssuer` | Switch to use new AAD issuer form `https://login.microsoftonline.com/{tenantId}/v2.0` (requires `-TenantId` + explicit `-FederatedSubject`). |
| `-FederatedSubject` | Explicit subject override. Legacy auto-computed format: `sc://AzureAD/{projectId}/{scId}`. New issuer portal format: `/eid1/c/pub/t/<token>/a/<token>/sc/{projectId}/{scId}` (must be supplied exactly when using `-UseAadIssuer`). |
| `-FederatedAudience` | Audience (default `api://AzureADTokenExchange`). |
| `-AssignSpContributorRole` | Optional subscription-level Contributor role assignment. |
| `-FederatedCredentialMaxRetries` / `-FederatedCredentialRetrySecondsBase` | Control retry behavior. |
| `-DebugWifCreation` / `-DebugFederatedCredential` | Emit verbose debug output. |
| `-ProceedOnDuplicateNoVisibility` | Proceed when duplicate SC exists but cannot be listed. |
| `-ExistingServiceConnectionId` | Provide SC id to compute subject when visibility missing. |
| `-AutoRepairAzDevOpsExtension` | Auto-repair azure-devops CLI extension on access errors. |

## Typical Execution Flows

1. Fresh Environment:
   - SP/app optionally created.
   - Project id resolved via CLI or REST fallback.
   - WIF SC created (7.1 attempt -> possibly 7.0 fallback) with payload self-heal.
   - FederatedSubject computed and federated credential ensured (with retries & CLI fallback).
2. Duplicate SC Visible:
   - 409 triggers list; existing WIF SC id found -> treat as success -> compute subject -> credential ensured.
3. Duplicate SC Not Visible:
   - Without switches: script fails fast (permission guidance).
   - With `-ProceedOnDuplicateNoVisibility`: script continues (skips credential unless subject provided or `-ExistingServiceConnectionId` supplied).
   - With both `-ProceedOnDuplicateNoVisibility -ExistingServiceConnectionId`: subject computed and credential ensured.

## Federated Credential Remediation Guide

If the federated credential does not exist (pipelines fail with AADSTS70025 / missing federated credential):

### 1. Gather Required IDs

- Azure AD Application (client) ID: `az ad app list --display-name <name> --query "[0].appId" -o tsv`
- Application Object ID (for federated credential operations): `az ad app list --display-name <name> --query "[0].id" -o tsv`
- Azure DevOps project id: `az devops project show --org https://dev.azure.com/<org> --project <project> --query id -o tsv`
- Service connection id (if not visible via CLI, retrieve from a user with permission in Project Settings > Service connections > JSON view).

### 2. Compose / Provide Federated Subject

Legacy (DevOps OIDC issuer) format (auto-computed if omitted):

```text
sc://AzureAD/<projectId>/<serviceConnectionId>
```

New AAD issuer portal-exposed format (must be copied verbatim from the Azure DevOps service connection UI when `-UseAadIssuer` is used):

```text
/eid1/c/pub/t/<tenantToken>/a/<audToken>/sc/<projectId>/<serviceConnectionId>
```

The middle `t/<tenantToken>/a/<audToken>` segments are dynamic and cannot currently be derived locally; failure to supply the exact string results in a non-matching or unusable credential.

### 3. Create Federated Credential Manually

Option A (Modern CLI requiring --parameters) — legacy issuer example:

```powershell
$federated = @{ name = "ado-wif-manual"; issuer = "https://vstoken.dev.azure.com/<org>"; subject = "sc://AzureAD/<projectId>/<scId>"; audiences = @("api://AzureADTokenExchange") } | ConvertTo-Json -Depth 6
$temp = New-TemporaryFile
$federated | Set-Content -Path $temp -Encoding utf8
az ad app federated-credential create --id <appObjectId> --parameters @$temp
```

Option B (Older CLI still accepting inline flags) — legacy issuer example:
Option C (Modern CLI with new AAD issuer & portal subject):

```powershell
$portalSubject = '/eid1/c/pub/t/<tenantToken>/a/<audToken>/sc/<projectId>/<scId>'
$fc = @{ name = 'ado-wif-portal'; issuer = "https://login.microsoftonline.com/<tenantId>/v2.0"; subject = $portalSubject; audiences = @('api://AzureADTokenExchange') } | ConvertTo-Json -Depth 6
$tmp = New-TemporaryFile; $fc | Set-Content -Path $tmp -Encoding utf8
az ad app federated-credential create --id <appObjectId> --parameters @$tmp
```

> NOTE: The script now enforces explicit `-FederatedSubject` when `-UseAadIssuer` is provided and performs normalization to remove stray leading/trailing backslashes produced by some shells.

```powershell
az ad app federated-credential create --id <appObjectId> --name ado-wif-manual --issuer "https://vstoken.dev.azure.com/<org>" --subject "sc://AzureAD/<projectId>/<scId>" --audiences api://AzureADTokenExchange
```

### 4. Verify Credential

```powershell
az ad app federated-credential list --id <appObjectId> -o table
```

Confirm row displays expected issuer + subject.

### 5. Run a Pipeline Using the Service Connection

Trigger a pipeline referencing the WIF service connection; ensure token exchange succeeds (no AADSTS70025).

### Common Failure Causes

| Symptom | Likely Cause | Action |
|---------|--------------|--------|
| 404 on federated-credential create | Wrong app object id | Re-query application id & object id. |
| Error requiring --parameters | Newer CLI format | Use JSON file with `--parameters`. |
| AADSTS500011 / resource not found | Wrong audience | Ensure audience is `api://AzureADTokenExchange`. |
| AADSTS70025 missing cred | Credential not created or wrong subject | Recreate with exact subject format (legacy vs portal style mismatch). |
| Trailing backslash in subject | Shell escaping or copy artifact | Re-run with cleaned subject or rely on script normalization (added Oct 2025). |
| Subject normalization warning | Pattern does not end with `/sc/<guid>/<guid>` | Verify copied subject; ensure no trailing slash/backslash. |
| 403 or permission denied in ADO | PAT lacks Service Connection permissions | Grant "Manage service connections" or have admin approve connection. |

## Extension Corruption / Access Denied

If you see `Access is denied: ... .azure\\cliextensions\\azure-devops`:

- Use `-AutoRepairAzDevOpsExtension` or manually:

```powershell
az extension remove --name azure-devops
az extension add --name azure-devops
```

- Re-run bootstrap.

## Minimal Example Commands

Fresh create:

```powershell
pwsh ./bootstrap-and-build.ps1 -InstanceNumber 002 -Location canadacentral -ADOCollectionName <org> -AzureDevOpsProject <project> -AzureDevOpsRepo <repo> -CreateWifServiceConnection
```

Proceed when duplicate invisible but id known:

```powershell
pwsh ./bootstrap-and-build.ps1 -InstanceNumber 002 -Location canadacentral -ADOCollectionName <org> -AzureDevOpsProject <project> -AzureDevOpsRepo <repo> -CreateWifServiceConnection -ProceedOnDuplicateNoVisibility -ExistingServiceConnectionId <scId>
```

Manual subject override:

```powershell
pwsh ./bootstrap-and-build.ps1 -InstanceNumber 002 -Location canadacentral -ADOCollectionName <org> -AzureDevOpsProject <project> -AzureDevOpsRepo <repo> -CreateWifServiceConnection -FederatedSubject "sc://AzureAD/<projectId>/<scId>"
```

## Follow Ups

Planned (if needed):

- Optional REST-only fallback enumeration for service connections when PAT cannot list via CLI.
- Auto-detection & repair of malformed federated subject (delete & recreate) when normalization changes it.
- Unit-test style mocks for duplicate and permission scenarios.
- Potential automated capture of portal-style subject via future Azure DevOps API (if exposed).

-- End
