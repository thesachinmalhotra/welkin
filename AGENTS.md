# Welkin

Zero-code configuration and composition layer for event-driven economic
processing and archival.

```
Any producer
    ↓
OpenMeter Collector        ← the only normalization boundary
    ↓
Canonical CloudEvent       ← the platform contract
    ├──→ Economic Plane:   OpenMeter → native Stripe integration → Invoice
    └──→ Archive Plane:    Broker / drop_on → Object Storage → Parquet
```

## Canonical sources

- **Welkin Prose** (Linear, the "Welkin Prose" series) — architecture and
  operating model. Read the relevant chapter before touching its boundary.
  Prose wins every disagreement between sources.
- **Repository** — authoritative for executable configuration.
- **CI/E2E and runtime evidence** — authoritative for what is actually
  verified. Nothing else counts as verification.

Discrepancies get recorded and reconciled, never guessed away.

## Rules

1. Compose, don't build. Before adding anything, name the upstream owner
   (OpenMeter, Collector, broker, object storage, Kubernetes, Flux, Timoni).
   No upstream owner → document the gap first.
2. Canonicalize once at the Collector boundary. Downstream never re-translates
   producer formats and never sees a second canonical schema.
3. Planes share the event, not failure fate. Archive failures must never fail
   Economic processing and vice versa.
4. Canonical CloudEvent changes are cross-plane changes — identify impact on
   ingestion, archive, fixtures, mappings, docs, consumers before modifying.
5. One active production-readiness objective at a time. No new features while
   P0/P1 blockers remain. Stop when it closes.
6. Smallest coherent change for the active objective. No drive-by cleanup.
7. No claimed success without evidence. Label claims FACT / INFERENCE /
   HYPOTHESIS / VERIFIED / UNVERIFIED. Never weaken tests or contracts to go
   green.
8. Verify the real boundary, not the build: a passing parser or unit test is
   not runtime evidence. Then try to disprove your fix.
9. New findings are recorded, not chased. Queue them or move the execution
   pointer explicitly.
10. Terminology is fixed: Economic Plane, Archive Plane, OpenMeter Collector,
    Canonical CloudEvent, Welkin. Do not rename.

## Session handoff

Every session ends with STATE, ACTIVE OBJECTIVE, CURRENT GATE, FACTS,
EVIDENCE, CHANGES, COMMIT/PR, TESTS/CI/E2E, ADVERSARIAL RESULT, REGRESSIONS
CHECKED, OPEN QUESTIONS, NEXT ACTION.

## Commits

Conventional Commits: `<type>(<scope>): <description>`. Subject ≤ 72 chars,
imperative, no period, no `@latest`. Local validation green before push;
never commit secrets.
