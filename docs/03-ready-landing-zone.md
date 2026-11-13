# 03 · Ready — landing zone: what we assume, what we build

> CAF phase: **Ready**. A workload team does not build the landing zone. It consumes one and must be explicit about the contract.

## 1. Division of responsibility

| Layer | Owner | In this repository? |
|---|---|---|
| Management groups, subscriptions, Azure Policy, Defender for Cloud | Central IT (platform team) | No — assumed, listed below |
| Hub VNet, VPN/ExpressRoute gateway, Azure Firewall, DNS Private Resolver, central Log Analytics for platform logs | Central IT | No — referenced by parameters |
| Identity: Entra ID tenant, Entra Connect, PIM, break-glass | Central IT | No |
| **Integration spoke**: VNet, subnets, NSGs, route table, private DNS zones, private endpoints | **Workload team (this repo)** | **Yes** — `infra/modules/network.bicep` |
| **Workload resources**: Event Hubs, Azure SQL, APIM, Logic Apps, Functions, Key Vault, App Insights, alerts | **Workload team** | **Yes** |
| Workload Log Analytics workspace (application-level telemetry) | Workload team | Yes — platform logs still flow to the central workspace via policy |

This split follows the CAF *application landing zone* model: platform team provides guardrails and connectivity; workload team owns everything inside its subscription and resource groups, within those guardrails.

## 2. Assumptions about the platform landing zone

Stated so that they can be verified in wave 0 and so that nobody discovers in wave 1 that "the hub does not do that".

| # | Assumption | Verified how |
|---|---|---|
| LZ-1 | A hub VNet exists in Sweden Central with a VPN gateway (site-to-site to the data center, ≥ 1 Gbps, BGP) and Azure Firewall | Canary VM in spoke pings on-prem CRM host; firewall logs show the flow |
| LZ-2 | Spoke subscriptions are *corp* landing zones: hub peering with `useRemoteGateways`, forced tunnelling through the firewall via UDR | Peering created by platform pipeline on request; we attach our own route table with `0.0.0.0/0 → firewall` |
| LZ-3 | Private DNS zones for `privatelink.*` are **either** centrally managed (hub subscription, policy auto-registers A records) **or** workload-managed. Meridian's platform team chose **workload-managed zones with hub-side DNS Private Resolver forwarding** | `nslookup mer-int-dev-evh.servicebus.windows.net` from on-prem returns the private IP |
| LZ-4 | On-prem DNS has conditional forwarders for `*.privatelink.*` and the public service domains (`servicebus.windows.net`, `database.windows.net`, `vaultcore.azure.net`, `azurewebsites.net`, `azure-api.net`) pointing to the DNS Private Resolver inbound endpoint | same |
| LZ-5 | Azure Policy enforces: allowed locations (EU), diagnostic settings to central workspace, deny public network access on PaaS, require tags `costCenter`/`owner`, deny storage accounts without TLS 1.2 | `what-if` + policy compliance view before first deploy |
| LZ-6 | Entra ID groups exist for `int-platform-admins`, `int-developers`, `int-readers`; RBAC at subscription scope is managed by platform via PIM | Role assignments in this repo are **resource-to-resource** (managed identities) only, never user-to-resource |
| LZ-7 | Deployment identity is a workload identity (federated credential from GitHub Actions / Azure DevOps) with `Contributor` + `User Access Administrator` scoped to the workload resource group, **not** a service principal with a secret | `az login --federated-token` in the pipeline |
| LZ-8 | Outbound internet from the spoke goes through Azure Firewall; FQDN allow-list needed for: Event Hubs Kafka endpoints are private, so none; ACS Email; NuGet/npm only from build agents, not from the spoke | Firewall rule collection request raised in wave 0 |

If LZ-3 turns out to be "centrally managed zones", `network.bicep` is deployed with `createPrivateDnsZones=false` and private endpoints get their DNS records via the platform policy. The module supports both; the decision is a parameter, not a redesign.

## 3. Subscription and resource group layout

```
Subscription: sub-meridian-integration-dev      (corp landing zone)
└── rg-mer-int-dev-swc
    ├── network      (VNet, NSGs, RT, private DNS zones)
    ├── monitoring   (LAW, App Insights, action group)
    ├── keyvault
    ├── eventhubs
    ├── sql
    ├── apim
    ├── logicapp (+ storage)
    ├── functionapp (+ storage)
    └── alerts

Subscription: sub-meridian-integration-prod     (corp landing zone)
└── rg-mer-int-prod-swc                          (same shape, prod parameters)
```

One resource group per environment, not per service. Reasoning: the whole integration workload has one lifecycle and one owner; splitting resource groups by service only multiplies RBAC and deployment scopes. Separate subscriptions per environment give hard isolation of quotas, policies and blast radius.

## 4. Network design of the spoke

Address space `10.20.0.0/22` dev, `10.21.0.0/22` prod (allocated from the platform IPAM).

| Subnet | CIDR (dev) | Purpose | Delegation | NSG |
|---|---|---|---|---|
| `snet-pe` | 10.20.0.0/25 | Private endpoints for Event Hubs, SQL, Key Vault, storage accounts, Logic App, Function App | — | Default deny inbound from Internet; allow VirtualNetwork |
| `snet-apim` | 10.20.0.128/26 | API Management, internal VNet mode | — | APIM-specific rules (management 3443, LB 6390, outbound to Storage/SQL/KV/Monitor) |
| `snet-la` | 10.20.1.0/26 | Logic Apps Standard regional VNet integration | `Microsoft.Web/serverFarms` | Outbound only |
| `snet-fa` | 10.20.1.64/26 | Function App (Elastic Premium) VNet integration | `Microsoft.Web/serverFarms` | Outbound only |
| reserve | 10.20.2.0/23 | future: self-hosted agents, Data Factory IR | | |

Why **internal** APIM rather than external with a WAF: partners do not hit APIM directly. Exposure goes through the platform's shared Front Door / Application Gateway in the hub (LZ decision, not ours), which gives one WAF policy for the whole company. APIM therefore only needs a private IP. This is also why `snet-apim` is small.

Why no `GatewaySubnet` or `AzureFirewallSubnet`: they live in the hub. A spoke that contains its own gateway is not a spoke.

## 5. Identity design

Every Azure-to-Azure call uses a **system-assigned managed identity** and RBAC:

| Caller | Target | Role |
|---|---|---|
| Function App | Event Hubs | Azure Event Hubs Data Receiver |
| Function App | Azure SQL | db_datawriter via Entra group containing the identity |
| Function App | its storage account | Storage Blob Data Owner, Queue Data Contributor, Table Data Contributor (identity-based host storage; code runs from a package blob, no Azure Files share) |
| Function App | Key Vault | Key Vault Secrets User |
| Function App, Logic App, APIM | Application Insights | Monitoring Metrics Publisher — local auth on App Insights is disabled, telemetry is sent with Entra |
| Logic App host (user-assigned identity `mer-int-{env}-id-la-host`) | its storage account, Key Vault | Storage roles as above for blob/queue/table; Key Vault Secrets User to resolve the content-share connection string. The Azure Files share needs a key — the one storage exception, see [ADR-007](adr/ADR-007-identity-based-storage-and-no-keys.md) |
| Logic App workflows (system-assigned identity) | Event Hubs, Key Vault | Azure Event Hubs Data Receiver + Data Sender (partner-sync fan-out), Key Vault Secrets User |
| APIM | Key Vault | Key Vault Secrets User (named values) |
| On-prem CRM publisher | Event Hubs | Azure Event Hubs Data Sender — via **workload identity federation** is not available for on-prem Windows services, so this is the one place a service principal with a certificate is used (certificate in on-prem cert store, rotated yearly, documented exception). |
| GitHub Actions | resource group | Contributor + User Access Administrator via federated credential (OIDC) |

Local auth is disabled where the service allows it (`disableLocalAuth: true` on Event Hubs and App Insights, Entra-only on SQL, `allowSharedKeyAccess: false` on the Function App storage). There are no connection strings with keys in this repository, in any parameter file, or in any pipeline variable; the one key that must exist (Logic App content share) is generated by Bicep straight into Key Vault.

## 6. Wave 0 gate — the checklist that must be green before wave 1

- [ ] LZ-1..LZ-8 verified and recorded (who, when, evidence)
- [ ] Spoke deployed from `main` via pipeline, `what-if` shows no drift on re-run
- [ ] Canary VM in `snet-pe`: resolves and reaches on-prem CRM API (443) and on-prem Kafka (9092) — proves VPN + firewall + DNS
- [ ] On-prem job server: resolves `*.servicebus.windows.net` to a 10.20.x.x address — proves conditional forwarders
- [ ] Alert fires end-to-end: synthetic failure → Action Group → on-call phone, measured < 5 minutes
- [ ] Kafka runbooks written and reviewed by two engineers other than the author
- [ ] Data Migration Assistant compatibility scan of `crm_reporting` against Azure SQL: zero blocking findings
- [ ] Cost estimate for dev + prod approved (see [04 §8](04-target-architecture.md#8-cost))

---
Previous: [02 · Plan](02-plan-assessment.md) · Next: [04 · Target architecture](04-target-architecture.md)
