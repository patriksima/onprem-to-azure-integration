# ADR-009 · Azure Verified Modules for commodity resources, hand-written modules where the configuration is the point

**Status:** accepted · **Date:** 2026-02

## Context

The first version of `infra/` was entirely hand-written Bicep: nineteen modules, each wrapping one resource type with the diagnostics, private endpoint, RBAC and tagging conventions of this workload. It built cleanly and passed PSRule. The question in review was the obvious one: *why not [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/)?*

AVM is Microsoft's supported, versioned library of Bicep modules, one per resource type, with a consistent interface for the things every workload needs (private endpoints, diagnostic settings, role assignments, locks, tags) and with PSRule compliance built in. Platform teams in most enterprises either mandate it or are moving towards it.

## Options

| Option | For | Against |
|---|---|---|
| A. Everything hand-written | Every line explains itself; no external dependency; smallest ARM output | Reinvents conventions AVM already has; a reviewer rightly asks why; every security default is ours to get right and keep right |
| B. Everything AVM | Standard, maintained, WAF-aligned by construction; fewest lines of our own; what a corporate landing zone expects | The two or three places where *the configuration itself is the design* (identity-based Logic App storage, keyless Function App) become long `appSettingsKeyValuePairs` arrays inside a generic module call — correct, but the *why* disappears; version pinning becomes an ongoing chore; nested deployments make `what-if` output longer |
| **C. AVM for commodities, hand-written where the configuration carries the decision** | Gets the standard where standard is what you want, keeps readability where readability is the deliverable | Two styles in one repo; must be explicit about which is which and why |

## Decision

**Option C.**

| From AVM (`br/public:avm/res/...`, pinned) | Hand-written |
|---|---|
| Virtual network, NSGs, route tables, private DNS zones, private endpoints | `logicapp.bicep` — Logic Apps Standard with identity-based host storage and a Key Vault reference for the content share |
| Key Vault, Log Analytics, Application Insights, Action Group | `functionapp.bicep` — .NET 10 isolated, Elastic Premium, shared keys off, run-from-package |
| Storage accounts, Event Hubs namespace, SQL server and database | `apim-api.bicep` — the partner API: backend entity, Key Vault named value, policy, Defender for APIs onboarding |
| API Management service, App Service plans, user-assigned identity | |
| Metric alerts, scheduled-query alerts, activity-log alert | |

The hand-written modules may call AVM internally (for example `web/site` for the private endpoint and diagnostics plumbing) as long as the application settings remain an explicit, commented block. The pin table and parameter notes live in [`infra/AVM.md`](../../infra/AVM.md).

## Consequences

- **Versions are pinned and reviewed.** A Dependabot-style bump of AVM modules is a monthly chore with a PR; `what-if` shows what the new version changes. Unpinned (`:latest`) references are rejected in review.
- **Local builds need the registry.** `bicep build` restores modules from `mcr.microsoft.com`; a build agent without that egress needs the modules vendored or a private registry mirror (`br/<alias>`), which the platform team's landing zone typically provides.
- **PSRule becomes mostly about our choices**, not our mistakes: AVM modules are PSRule-clean, so every remaining finding is either a deliberate departure (recorded in `.ps-rule/suppressions.Rule.yaml`) or a bug in how we called the module.
- **Readers can skim the commodity and read the decisions.** `main.bicep` reads as an inventory; the three hand-written modules read as an argument.
- If AVM later publishes a pattern module that covers this shape (an integration-services pattern, say), this decision is revisited — a pattern module would replace most of `main.bicep`, and that is a different trade-off.
