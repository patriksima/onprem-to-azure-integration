# ADR-003 · API Management as the partner façade; tier decision kept open

**Status:** accepted, with an open question on tier · **Date:** 2026-02

## Context

Partners need a REST API to replace CSV-over-SFTP. Requirements: per-partner credentials and revocation, rate limiting, versioning (partners will not all move to v2 at once), request logging for dispute resolution, and a stable contract that survives the CRM being replaced later ([ADR-005](ADR-005-crm-stays-on-prem.md)).

Ingress for the whole company goes through the platform team's Front Door with WAF ([03 §4](../03-ready-landing-zone.md)).

## Options

| Option | Assessment |
|---|---|
| **A. API Management, internal VNet mode, behind platform Front Door** | Does everything in the list out of the box; one place to swap the backend; policies as code. Costs: Developer tier (dev) has no SLA; Premium (prod) is expensive. |
| B. Expose Logic App / Function HTTP endpoints directly through Front Door | Cheapest. No per-partner keys without custom code; rate limiting only at WAF granularity; versioning becomes URL routing in Front Door; no developer portal. Fine for one partner, not for five with different maturity. |
| C. Container Apps with an open-source gateway (Kong, Envoy) | Capable. Another runtime to operate for a four-person team; no benefit over APIM at this scale. |

## Decision

**Option A.** One API `partner-orders` v1, subscription key + client certificate per partner, `rate-limit-by-key` on subscription, correlation header propagation, backend = Logic App callback URL (later: CRM façade directly for reads). Policies live in `infra/apim/policies/`.

### Open question: Premium vs Standard v2 in production

| | Premium (classic) | Standard v2 |
|---|---|---|
| VNet | injection (internal mode) | integration (outbound) + private endpoint (inbound) |
| SLA | 99.95 %, multi-AZ | 99.95 % |
| Price (1 unit, SE Central) | ≈ €2,600/month | ≈ €650/month |
| Developer portal, workspaces, self-hosted gateway | yes | partial / no |
| Maturity in our platform's patterns | platform team has Premium elsewhere | new to them |

Standard v2 would cut the production bill by ~50 %. It was not chosen *yet* because (a) the platform team's Front Door → APIM pattern is proven with internal-mode Premium and unproven with a private endpoint on v2, and (b) v2 private endpoint inbound combined with VNet integration outbound needs to be validated against the hub firewall rules.

**Action:** validate Standard v2 in the dev subscription during wave 2 (which has spare capacity). Decide before the wave 3 prod deployment. The Bicep module takes the SKU as a parameter object; switching is a parameter change plus the `virtualNetworkType` → private endpoint swap, which is already written as a conditional in `apim.bicep`.

## Consequences

- Dev runs Developer tier: single instance, no SLA, ~€45/month. Dev is not for load tests; a short-lived Standard v2 instance is used for that.
- APIM deployment takes 30–45 minutes on classic tiers. Pipelines account for it; nobody waits on it for a Logic App change because APIM is a separate deployment stage with `what-if` skip when unchanged.
- The partner contract (OpenAPI in `infra/apim/openapi/`) is the product. Changes to it go through a review with the partner managers, not just engineering.
