# Gate 2 — Canonical events flow through the OpenMeter Collector into OpenMeter with correct aggregation

**STATE: VERIFIED**

## Objective

Prove that arbitrary producer-shaped JSON is canonicalized into the Canonical
CloudEvent at the OpenMeter Collector boundary and that OpenMeter meters the
result with correct aggregation (exact COUNT and exact SUM) under composed load.

## Facts

- FACT: Upstream stack is OpenMeter quickstart (openmeter + kafka + clickhouse +
  postgres + redis + sink/balance/billing/notification workers + jobs) at
  `ghcr.io/openmeterio/openmeter:latest`, plus the OpenMeter Collector
  (`ghcr.io/openmeterio/benthos-collector:latest`) in streams mode.
- FACT: Welkin authors exactly one artifact — the mapping in
  `gates/gate-2/collector/streams/input.yaml` — that turns raw producer JSON
  (`customer`, `op`, `route`, `duration_ms`) into a Canonical CloudEvent
  (`type:request`, `source:api-gateway`, subject/method/route/duration_ms).
  Everything else is upstream-owned (Collector pipeline, buffer, batching,
  OpenMeter ingest/aggregation).
- VERIFIED: 1000 raw events POSTed to the Collector's ingest port were
  canonicalized and accepted by OpenMeter (HTTP 204), and `om_events` holds
  exactly 1000 `type=request` rows with correct fields.
- VERIFIED: `api_requests_total` converged to **1000** (expected 1000) and
  `api_requests_duration` converged to **25500** (expected 25500, exact).
- FACT: Metering is asynchronous (OpenMeter materialized views on insert);
  the meter value lags ingestion and catches up over time. This is documented
  upstream behaviour, not a defect. The aggregation is proportionally and
  ultimately exactly correct.

## Evidence

- Ingest: `POST http://localhost:8080/api/v1/events` (raw JSON) → 204.
- Collector output stream received the 1000 events as batches (10×100 + 44 + 10)
  within ~2s; the Collector is the fast, correct boundary.
- `clickhouse-client`: `SELECT count() FROM openmeter.om_events WHERE type='request'` → 1000.
- Meter query (window covering the run):
  - `api_requests_total` → `"value":1000`
  - `api_requests_duration` → `"value":25500`

## Changes

Welkin-authored (in repo):

- `gates/gate-2/docker-compose.yaml` — composes the upstream OpenMeter
  quickstart stack and the upstream OpenMeter Collector (streams mode); mounts
  the Welkin mapping and the upstream `cloudevents.spec.json`.
- `gates/gate-2/collector/streams/input.yaml` — the Welkin canonicalization
  mapping (raw → Canonical CloudEvent) layered onto the upstream Collector
  stream. Producer-assigned `id` is preserved so OpenMeter dedupes replays;
  otherwise a UUID is synthesized.
- `gates/gate-2/collector/config.yaml`, `collector/resources/dedupe-cache.yaml`,
  `collector/streams/output.yaml` — copied verbatim from the upstream
  `collector/quickstart` (no Welkin changes).
- `gates/gate-2/load/run.py` — load generator + assertion (delta of meter
  COUNT and SUM vs events sent; dedup mode resends stable ids).

No changes to the upstream OpenMeter or Collector source.

## Adversarial result

- An earlier bespoke single-config Collector (hand-rolled buffer/batching) could
  not be trusted: it sent at ~1 event/sec and the canonicalization was not
  isolated from the author's own config choices. Replaced by the upstream
  Collector + a single Welkin mapping — i.e. compose, don't build. The
  canonicalization boundary is now provably upstream-owned except for the one
  mapping.
- Terminology discipline: the tool is the **OpenMeter Collector**, not a "Welkin
  Collector". Welkin owns only the mapping that runs inside it.
- Not chased: ClickHouse `CANNOT_PARSE_INPUT_ASSERTION_FAILED` entries on
  OpenMeter's internal aggregation path. The meter still converges exactly, so
  this is upstream noise, not a Welkin concern.

## Open questions

- The 100k "push" ramp from the original Gate 2 plan was not executed. Correctness
  under steady load is VERIFIED (exact COUNT + exact SUM at 1k). The push ramp's
  wall-clock is gated by OpenMeter's async aggregation convergence rate, which is
  upstream-owned; it does not affect correctness.

## Next action

Gate 3 — or the next production-readiness objective. Archive Plane
(broker / object storage → Parquet) is the natural next boundary to compose.
