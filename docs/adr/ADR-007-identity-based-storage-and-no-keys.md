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
| Storage — Function App host | `allowSharedKeyAccess: false`; `AzureWebJobsStorage__accountName`; code deployed with `WEBSITE_RUN_FROM_PACKAGE` pointing at a blob in the same account (no Azure Files share) | The runtime uses its MI with Blob Data Owner / Queue Data Contributor / Table Data Contributor on its own account. No storage connection string exists anywhere. |
| Storage — Logic App host | Blob/queue/table identity-based (`AzureWebJobsStorage__managedIdentityResourceId` + service URIs, user-assigned identity `mer-int-{env}-id-la-host`); **Azure Files content share still needs a key** — Logic Apps Standard on the Workflow Service plan cannot run without it, and Azure Files has no identity auth for this path | `allowSharedKeyAccess` stays `true` on the Logic App account only. The key never appears in app settings: Bicep writes the connection string into Key Vault and `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` is a Key Vault reference resolved by the host identity. This is the second documented exception after the on-prem SPN certificate. |
| Application Insights | `disableLocalAuth: true`; producers send with Entra (`APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`, Monitoring Metrics Publisher role) | Instrumentation keys and connection strings alone cannot ingest telemetry. |
| Key Vault | `enableRbacAuthorization: true` | No access policies; Secrets User role per identity. Holds only what cannot be MI: ACS connection, partner credentials, the Logic App content-share connection string, the APIM callback signature. |
| APIM → Key Vault | MI + named values with KV reference | Policy fragments reference `{{partner-x-secret}}`; rotation needs no APIM deployment. |
| Deployment | GitHub Actions / Azure DevOps with **workload identity federation** | No service-principal secret in pipeline variables. |

Verified in CI by PSRule for Azure rules `Azure.EventHub.DisableLocalAuth`, `Azure.SQL.AADOnly`, `Azure.Storage.DisableSharedKey` (custom), `Azure.KeyVault.RBAC`.

## What this costs

- **Logic Apps Standard with identity-based host storage** requires the WS plan and specific app settings; a wrong setting produces an opaque "storage unavailable" error. Documented in `logicapp.bicep` comments and tested in dev first.
- **Role assignment propagation** takes up to several minutes; the first deployment of a new environment may need a restart of the Function/Logic App after RBAC lands. The pipeline has an explicit wait-and-restart step rather than pretending this does not happen.
- **Local development** uses the developer's Entra identity (`DefaultAzureCredential`) against dev resources via VPN or a Dev Box in the spoke — no "copy the connection string into local.settings.json."
- **One exception** (on-prem SPN certificate) is listed in [03 §5](../03-ready-landing-zone.md#5-identity-design) with an owner and rotation date. Exceptions that are written down are controls; exceptions that are not are incidents.
