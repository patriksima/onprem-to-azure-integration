# ADR-008 · Consumer behaviour switched by one `CONSUMER_MODE` setting

**Status:** accepted · **Date:** 2026-02

## Context

Wave 1 runs new consumers in parallel with old jobs. Each consumer must be able to run in a non-destructive *shadow* mode and a *live* mode, and the switch must be the rollback mechanism — fast, auditable, and not a code deployment.

## Options

1. **Azure App Configuration with feature flags** — central, dynamic, nice UI. Another resource with a private endpoint and RBAC; dynamic refresh means a flag can change under a running batch; one more thing to explain to support.
2. **Separate deployments / slots** — shadow and live as different app instances. Doubles the plan cost; the diff between them is one behaviour, not two codebases.
3. **One app setting per consumer, `CONSUMER_MODE=shadow|live` (+ `TARGET_SCHEMA` for the reporting consumer)**, set by the deployment pipeline from the environment parameter file. Changing it restarts the app, which is desirable: a batch is never half-shadow, half-live.

## Decision

**Option 3.** The setting is a Bicep parameter → app setting; a change is a PR to the parameter file and a pipeline run (≈ 10 minutes including restart and health check). That PR is the audit trail. For the Logic Apps, the same setting is read by workflows via `appsetting('CONSUMER_MODE')` and gates the outbound HTTP action with a condition.

## Consequences

- Rollback for wave 1 and wave 2 is literally `CONSUMER_MODE: live → shadow` in `prod.bicepparam`. Rehearsed in dev.
- Code must branch on the mode in exactly one place per consumer (the sink). Reviewers reject PRs that sprinkle mode checks through business logic.
- The setting is removed from the code after wave 3 closes — it is migration scaffolding, not a product feature. A ticket exists for its removal with the wave 4 checklist.
- If the organisation later adopts App Configuration for product feature flags, the consumers can move to it then; nothing in this design prevents it.
