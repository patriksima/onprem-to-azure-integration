# ADR-007 · No shared keys or connection strings; managed identity everywhere

**Status:** accepted · **Date:** 2026-02

## Context

The on-prem estate has service-account passwords in config files, SFTP password auth, and Kafka in plaintext ([02 §2.5](../02-plan-assessment.md)). Platform policy denies public network access on PaaS but does not (yet) deny local authentication. The team could carry the old habits into Azure with connection strings in Key Vault and call it secure.

## Decision

Every Azure-to-Azure authentication uses a **system-assigned managed identity with RBAC**, and local/key-based auth is **disabled at the resource** where the service supports it:

| Resource | Setting | Consequence |
|---|---|---|
| Event Hubs | `disableLocalAuth: true` | SAS policies cannot be created; the Kafka endpoint accepts only OAuth. The on-prem publisher authenticates with an SPN certificate (the one non-MI identity, documented exception). |
| Azure SQL | `azureADOnlyAuthentication: true` | No SQL logins, including `sa`-style admin. DBA access via Entra group. |
| Storage (Function & Logic App host storage) | `allowSharedKeyAccess: false`; host configured with `AzureWebJobsStorage__accountName` | The runtime uses its MI with Blob Data Owner / Queue Data Contributor / Table Data Contributor on its own account. No storage connection string exists anywhere. |
| Key Vault | `enableRbacAuthorization: true` | No access policies; Secrets User role per identity. Holds only what cannot be MI: ACS connection, partner credentials. |
| APIM → Key Vault | MI + named values with KV reference | Policy fragments reference `{{partner-x-secret}}`; rotation needs no APIM deployment. |
| Deployment | GitHub Actions / Azure DevOps with **workload identity federation** | No service-principal secret in pipeline variables. |

Verified in CI by PSRule for Azure rules `Azure.EventHub.DisableLocalAuth`, `Azure.SQL.AADOnly`, `Azure.Storage.DisableSharedKey` (custom), `Azure.KeyVault.RBAC`.

## What this costs

- **Logic Apps Standard with identity-based host storage** requires the WS plan and specific app settings; a wrong setting produces an opaque "storage unavailable" error. Documented in `logicapp.bicep` comments and tested in dev first.
- **Role assignment propagation** takes up to several minutes; the first deployment of a new environment may need a restart of the Function/Logic App after RBAC lands. The pipeline has an explicit wait-and-restart step rather than pretending this does not happen.
- **Local development** uses the developer's Entra identity (`DefaultAzureCredential`) against dev resources via VPN or a Dev Box in the spoke — no "copy the connection string into local.settings.json."
- **One exception** (on-prem SPN certificate) is listed in [03 §5](../03-ready-landing-zone.md#5-identity-design) with an owner and rotation date. Exceptions that are written down are controls; exceptions that are not are incidents.
