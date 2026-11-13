# Azure Verified Modules in this repository

Commodity resources come from [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/) (`br/public:avm/res/...`). Three modules are hand-written because their configuration *is* the design decision. Rationale: [ADR-009](../docs/adr/ADR-009-azure-verified-modules.md).

## Pinned versions

Every reference is pinned to an exact version. All pins were the latest published tag on 2026-11-13.

| AVM module | Version | Used in | Replaces (hand-written, pre-ADR-009) |
|---|---|---|---|
| `network/virtual-network` | 0.10.2 | `network.bicep` | raw VNet + subnets + peering |
| `network/network-security-group` | 0.5.4 | `network-security.bicep` (×4) | raw NSGs |
| `network/route-table` | 0.5.0 | `network-security.bicep` (×2) | raw route tables |
| `network/private-dns-zone` | 0.8.1 | `network.bicep` | `private-dns.bicep` (deleted) |
| `network/private-endpoint` | 0.12.1 | `logicapp.bicep`, `functionapp.bicep` | `private-endpoint.bicep` (deleted); other resources use their module's built-in `privateEndpoints` parameter |
| `network/public-ip-address` | 0.13.0 | `apim.bicep` | raw public IP |
| `managed-identity/user-assigned-identity` | 0.6.0 | `main.bicep` | `identity.bicep` (deleted) |
| `operational-insights/workspace` | 0.16.1 | `monitoring.bicep` | raw workspace |
| `insights/component` | 0.8.0 | `monitoring.bicep` | raw Application Insights |
| `insights/action-group` | 0.8.0 | `monitoring.bicep` | raw action group |
| `key-vault/vault` | 0.14.2 | `keyvault.bicep` | raw Key Vault + seed secrets + role assignments |
| `storage/storage-account` | 0.33.1 | `storage.bicep` | raw storage account, containers, PEs; also replaces `storage-key-secret.bicep` (deleted) via the module's secrets-export parameter |
| `event-hub/namespace` | 0.15.2 | `eventhubs.bicep` | raw namespace, hubs, consumer groups |
| `sql/server` | 0.23.0 | `sql.bicep` | raw server, database, auditing, PE |
| `api-management/service` | 0.15.0 | `apim.bicep` | raw APIM service |
| `web/serverfarm` | 0.7.0 | `logicapp.bicep`, `functionapp.bicep` | raw App Service plans |
| `insights/metric-alert` | 0.4.1 | `alerts.bicep`, `alerts-log.bicep` | raw metric alerts |
| `insights/scheduled-query-rule` | 0.6.1 | `alerts-log.bicep` | raw scheduled-query alerts |
| `insights/activity-log-alert` | 0.4.2 | `alerts.bicep` | raw Service Health alert |
| `insights/webtest` | 0.3.2 | `alerts-log.bicep` | raw availability test (optional) |

## Hand-written on purpose

| Module | Why not AVM |
|---|---|
| `logicapp.bicep` (site) | The app settings — identity-based host storage plus a Key Vault reference for the content share — are the design. AVM `web/site` would hide them in a generic array one nested deployment deeper. Plan and private endpoint are AVM. |
| `functionapp.bicep` (site) | Same reasoning for the keyless, run-from-package host. Plan and private endpoint are AVM. |
| `apim-api.bicep` | The partner API contract: backend entity, Key Vault named value, policy, Defender for APIs onboarding. AVM's APIM module can declare APIs, but the policy and backend wiring read better as first-class resources. |
| `rbac.bicep` | Cross-resource role assignments that need principal IDs from sites created later in the graph; AVM modules assign roles only on their own resource. |

## Behaviour notes worth knowing

- **APIM `publicNetworkAccess`** is left at the module default (`Enabled`). With classic VNet injection in internal mode this setting cannot be `Disabled`; the gateway has no public listener regardless. The Standard public IP exists for the management plane only.
- **Logic App content-share key** is now written to Key Vault by the storage module's secrets export instead of a separate helper module. Same outcome: the key never appears in app settings, parameters or deployment outputs.
- **Diagnostic settings** for AVM-backed resources use the module's `diagnosticSettings` parameter with the shared shape in `conventions.bicep`. The two raw sites and the SQL `master` database keep explicit `Microsoft.Insights/diagnosticSettings` resources.
- **Names, tags, network rules, alert names and metrics are unchanged** from the hand-written version, so PSRule suppressions and the docs still match.

## Updating

1. Find the latest tags: `git ls-remote --tags https://github.com/Azure/bicep-registry-modules 'refs/tags/avm/res/<path>/*'`
2. Bump the version in the `br/public:` reference; read the module's changelog for breaking parameter changes (AVM is pre-1.0, so minor versions can break).
3. `bicep build` + `what-if` against dev. CI runs PSRule on the expanded result.
4. Never use `:latest` or an unpinned reference.

## Building without registry access

`bicep build` restores modules from `mcr.microsoft.com`. In an environment without that egress (some corporate build agents), point a `br/<alias>` in `bicepconfig.json` at an internal registry mirror, or vendor the module sources from the tags in [Azure/bicep-registry-modules](https://github.com/Azure/bicep-registry-modules) and rewrite the references to local paths for the build only.
