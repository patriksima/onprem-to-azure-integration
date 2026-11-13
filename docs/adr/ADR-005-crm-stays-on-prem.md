# ADR-005 · The CRM stays on-prem; the integration layer makes it replaceable

**Status:** accepted · **Date:** 2026-01 · **Deciders:** head of IT, CFO, integration architect

## Context

The CRM is a 12-year-old .NET Framework application with a 180 GB SQL Server database. It is the system of record for customers and orders. It has no API; every integration reads or writes its database directly. The partner-sync job writes stock levels straight into OLTP tables, bypassing business logic ([02 §2.4](../02-plan-assessment.md)).

The data center lease ends in 14 months. The integration program has four people.

## Options

| Option | Reality check |
|---|---|
| A. Lift the CRM to Azure VMs (rehost) | Technically a weekend. But then every CRM screen round-trips to a database that moved with it — fine — while the business still has a 12-year-old application, now with VM patching in Azure instead of on-prem. Buys nothing except data center exit. |
| B. Replace with SaaS CRM (Dynamics 365 / Salesforce) | The right long-term answer for most mid-sized distributors. 12–18 months, a different budget line, a different team, heavy data migration and process change. Cannot be done inside this program's window without starving the integration work. |
| C. Rebuild the CRM | Longer than B, with less certainty. |
| **D. CRM stays on-prem on refreshed hardware (or colocation); this program builds the integration layer so that A/B/C becomes a contained decision later** | Decouples the lease deadline from the CRM decision. The on-prem footprint shrinks to two application servers, one SQL AG pair, and a VPN endpoint — small enough for a colocation rack or a small server room. |

## Decision

**Option D.** The CRM and its OLTP database stay on-prem. The program delivers:

1. **Events as the integration contract.** Everything downstream consumes `crm.*` events from Event Hubs, never the CRM database. When the CRM is replaced, the replacement must emit the same events; consumers do not change.
2. **A thin CRM façade API** (built by the application team, scope agreed: `GET customers/{id}`, `GET/POST orders`, `PUT stock-levels`). All writes into the CRM — including partner stock imports — go through it. Direct database access from integrations is removed by the end of wave 3.
3. **Hybrid networking as a first-class concern** — VPN via hub, private DNS from on-prem, the publisher's SPN certificate: all designed, not improvised.

The CRM decision (B vs C) is scheduled as a separate initiative starting after wave 3, informed by what the program learns about the actual integration surface.

## Consequences

- The program's architecture is hybrid for its entire life, not just during migration. Latency between Logic Apps and the CRM façade (≈ 15–25 ms over VPN) is acceptable for partner flows; it would not be for an interactive UI — which is why nothing interactive crosses the VPN.
- The CFO signed a smaller hardware refresh (two hosts, one storage array) instead of a full data center renewal. That is the financial shape of this decision.
- The application team gains a deliverable (the façade) with a hard dependency from wave 3. Tracked as a program risk; the fallback for stock import is a staging table + CRM-side stored procedure, which is worse but unblocks wave 3.
- When the CRM is eventually replaced, the measurable success of this ADR is: *integration consumers and partners do not notice.*
