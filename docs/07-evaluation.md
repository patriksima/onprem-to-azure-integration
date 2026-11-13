# 07 · Evaluation — did the migration deliver what it promised?

> A migration without an evaluation is a project that ended, not a program that succeeded. This document is written *before* the program starts, so that the criteria cannot be adjusted to fit the result afterwards.

## 1. When and who

| Checkpoint | When | Owner | Audience |
|---|---|---|---|
| Wave exit review | end of each wave, before the next starts | integration architect | program steering |
| **30-day review** | 30 days after wave 3 go-live | integration architect + business owners | steering, IT management |
| **90-day review** | 90 days after wave 3 | same + finance | steering, CFO |
| **Annual review** | 12 months after wave 3, then yearly | run-state owner | IT management; feeds the CRM decision ([ADR-005](adr/ADR-005-crm-stays-on-prem.md)) |

The 30-day review answers "is it stable and are people using it". The 90-day review answers "did we get the outcomes and the money right". The annual review answers "is the architecture still the right one".

## 2. Outcome scorecard — the promises from [01 §4](01-strategy.md#4-business-outcomes-and-how-they-are-measured)

Filled in at the 90-day review. Columns are deliberately *target / actual / verdict / why*; a verdict without a why is useless to the next program.

| Outcome | Metric | Baseline | Target | Actual (90 d) | Verdict | Why / action |
|---|---|---|---|---|---|---|
| Exit the data center on time | workloads still on-prem at lease end | all | CRM only | | | |
| Failures detected by IT, not business | mean time to detect | next business day | < 15 min | | | |
| Partners on API | count of top-5 partners migrated | 0 | 5 within 6 months | | | |
| Faster change | lead time for a new event consumer | weeks | days | | | |
| Reporting freshness | order → dashboard lag, p95 | up to 24 h | < 15 min | | | |

Verdicts: **met**, **partially met** (with the gap quantified), **not met**, **not yet measurable** (with the date it will be). "Partially met" without a number is "not met".

## 3. NFR verification — [02 §3](02-plan-assessment.md#3-non-functional-requirements)

Each NFR gets one of: verified by measurement, verified by test, verified by inspection, not verified. The method is fixed here; only the result column is filled in later.

| NFR | Method | Evidence location | Result |
|---|---|---|---|
| NFR-01, 02 availability | measurement, 90-day SLO report | LAW workbook "SLO" | |
| NFR-03, 04 latency | measurement, p95/p99 over 30 days | App Insights custom metrics | |
| NFR-05 throughput | load test in dev at 10× peak, before wave 3 go-live | test report in repo `tests/load/` | |
| NFR-06 RPO/RTO | DR drill: redeploy `infra/` to paired region, restore SQL, replay 1 h of events | drill report, timed | |
| NFR-07 replay | replay one day from Capture in dev | runbook execution log | |
| NFR-08 integrity | reconciliation query at wave 1 exit; idempotency unit + integration tests | reconciliation workbook, CI test results | |
| NFR-09, 10, 11 security & compliance | PSRule CI green; Defender for Cloud secure score; penetration test of partner API by the platform security team; data-residency policy compliance report | CI logs, Defender, pentest report | |
| NFR-12 observability | chaos test: inject failure in each consumer, measure alert-to-human time | hypercare log | |
| NFR-13 maintainability | timed exercise: new consumer from template to dev by an engineer who did not build the platform | exercise log | |
| NFR-14 operability | % of hypercare incidents resolved by tier-1 with runbooks only | hypercare log | |
| NFR-15 cost | actual vs estimate, 3 consecutive months | Cost Management export | |
| NFR-16 reversibility | rollback executed in dev for each wave; time recorded | rehearsal log | |

## 4. Cost evaluation

Estimate from [04 §8](04-target-architecture.md#8-cost) vs actuals. The interesting rows are the deltas and their explanations, not the totals.

| Item | Estimated | Actual m1 | Actual m2 | Actual m3 | Delta | Explanation |
|---|---|---|---|---|---|---|
| APIM | | | | | | |
| Logic Apps Standard | | | | | | |
| Functions EP1 | | | | | | |
| Event Hubs | | | | | | |
| Azure SQL | | | | | | |
| Networking (PE, DNS, egress through firewall) | | | | | | |
| Monitoring (ingestion!) | | | | | | |
| **Total** | **≈ €3,840** | | | | | |

Plus the other side of the ledger, which nobody writes down and everybody later wishes they had:

| Avoided / removed cost | Amount | Confirmed by |
|---|---|---|
| Data center lease share for retired hosts | | facilities |
| SQL Server Standard licences no longer renewed | | licensing |
| Hardware refresh not purchased (3 servers + storage) | | finance |
| Kafka operations effort (hours/month before vs after) | | integration team time tracking |
| Incident cost: business-reported integration failures before vs after | | support ticket system |

The 90-day cost verdict is the Azure bill **minus** this table. If the first row of this table is empty at the review, the review is incomplete.

## 5. Technical health review

Checked at 90 days and annually:

- [ ] `what-if` on `main` shows zero drift in prod
- [ ] PSRule has no suppressed rules without a dated justification
- [ ] every alert in [06 §3](06-operate.md#3-alert-catalogue) fired at least once in the period, or its threshold has been reviewed
- [ ] no alert fired more than 3× without an action (fatigue check)
- [ ] poison-messages: count, mean time to triage, oldest untriaged
- [ ] `processed_events` growth and purge policy working
- [ ] Event Hubs: peak TU usage vs cap; partition utilisation (are 4 partitions still the right call — [ADR-001](adr/ADR-001-event-hubs-instead-of-kafka.md))
- [ ] secrets: none expired, none past 12 months, SPN certificate rotation done and logged
- [ ] all decommission checklist items from [05 §5](05-migration-plan.md#5-wave-4--decommission-weeks-3340) closed, with evidence
- [ ] open ADR questions resolved or re-dated ([ADR-003](adr/ADR-003-apim-as-partner-facade.md) tier decision)
- [ ] `CONSUMER_MODE` scaffolding removed ([ADR-008](adr/ADR-008-shadow-mode-over-feature-flags.md))

## 6. Retrospective — what the next program should know

Held once after wave 3 with the whole team and the business owners; 90 minutes; written up here in a page. Fixed prompts, so that the retrospective produces comparable output across programs:

1. Which risk from [02 §5](02-plan-assessment.md#5-risks-identified-during-assessment) materialised, and was the mitigation enough?
2. Which risk did we *not* list?
3. Which wave took longest versus plan, and was the cause technical, organisational, or external (partner, platform team)?
4. What did shadow mode find that we would otherwise have found in production?
5. Which landing-zone assumption ([03 §2](03-ready-landing-zone.md#2-assumptions-about-the-platform-landing-zone)) was wrong?
6. What would we cut from the scope if we did it again? What would we add?
7. What did the business notice? (Not what we delivered — what they *noticed*.)

## 7. Inputs to the CRM decision

The program's final deliverable is not the integration layer. It is the information the organisation needs to decide what to do about the CRM ([ADR-005](adr/ADR-005-crm-stays-on-prem.md)). After 12 months in run-state, this section is written as a one-page brief for the steering committee:

- the actual integration surface of the CRM (which events, which façade endpoints, which consumers depend on what) — i.e. what a replacement must provide
- the cost and incident history of the on-prem remainder
- how long the hardware refresh buys
- the two or three realistic options with rough sizing

That brief is the point at which this program hands over to the next one.

---
Previous: [06 · Operate](06-operate.md) · See also: [Architecture decision records](adr/)
