# Gate 1 — OpenMeter engine runs locally

**STATE: PARTIAL — smoke VERIFIED, load verification superseded by Gate 2**

## Objective

Get self-hosted OpenMeter running locally and verify it ingests and meters
events correctly. Stress testing of the raw engine was folded into Gate 2:
a direct-to-API benchmark measures a path production traffic never takes;
composed load (producer → Collector → OpenMeter) is the real boundary
(AGENTS.md rule 8).

## Facts

- FACT: Docker Engine v29.7.2 + Compose v5.4.0 operational on host.
- FACT: Host = Ubuntu 24.04, 16 CPUs, 11.33 GiB RAM (~9.7 GiB available).
- FACT: Upstream stack pinned at openmeterio/openmeter `65d575c1fa73222ee9a41894acdcb674a017077e`,
  quickstart compose profile.
- FACT: All 11 containers reached Healthy: openmeter, openmeter-jobs,
  kafka, clickhouse, postgres, redis, svix, balance-worker, billing-worker,
  notification-service, sink-worker.
- FACT: Smoke event roundtrip succeeded — ingest `HTTP 204`, meter
  `api_requests_total` subject `quickstart-curl` converged to `"value":1`
  within the polling window (<10s), proving API → Kafka → workers → ClickHouse.
- FACT: Idle stack footprint ≈ 1.2 GiB RAM total; heaviest components
  ClickHouse 468 MiB / Kafka 409 MiB.

## Evidence

- Smoke ingest: POST `http://localhost:48888/api/v1/events`
  (`application/cloudevents+json`) → 204.
- Smoke query: GET `/api/v1/meters/api_requests_total/query?subject=quickstart-curl`
  → `{"data":[{"subject":"quickstart-curl","value":1,...}]}`.
- Resource snapshot: `docker stats --no-stream` captured 2026-08-26 post-smoke.
- Method sources: upstream quickstart README (compose path chosen over
  Helm/kind for this gate).

## Changes

None to the welkin repository. Environment-only: cloned upstream repo to
`~/projects/personal/openmeter` (unvendored by design), docker group access
via `usermod`.

## Adversarial result

- Two aborted compose runs discarded partial image layers (no cache reuse) —
  resolved by backgrounded pull; no impact on final state.
- Dedup behavior NOT yet tested (moved to Gate 2 exit conditions).
- Load capacity unknown until Gate 2 composed-stress run.

## Open questions

- None blocking Gate 2.

## Next action

Gate 2 — Canonical events flow through the OpenMeter Collector into OpenMeter
with correct aggregation under ramping load (exact-SUM + dedup assertions,
eps/latency measured at the collector boundary).
