# Collector-First Archive Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Welkin Collector the single, OpenMeter-agnostic artifact that canonicalizes raw producer events and fans out to (a) the OpenMeter API (Economic Plane) and (b) our own Kafka topic consumed by an independent Archive Plane — portable to self-hosted and managed/SaaS OpenMeter alike.

**Architecture:** Producer → Collector (OpenMeter's `benthos-collector`) canonicalizes raw JSON to a Canonical CloudEvent (our only Welkin-owned mapping) and fans out via a Redpanda Connect broker: `openmeter` output (uniform API, works for any OpenMeter via `OPENMETER_URL`/`OPENMETER_TOKEN`) and a `kafka` output to topic `welkin_canonical`. A separate Redpanda Connect pipeline consumes `welkin_canonical` → `aws_s3` (MinIO) + `parquet_encode`. OpenMeter is an untrusted SaaS sink we do not control; the Archive Plane never reads OpenMeter internals, so it works under managed OpenMeter.

**Tech Stack:** Redpanda Connect / `ghcr.io/openmeterio/benthos-collector`, OpenMeter (self-hosted quickstart for local test, cloud API for prod), Kafka (from OpenMeter quickstart), MinIO (S3-compatible), `mc` CLI, `curl` (upstream API calls only — no authored code).

## Global Constraints

- **Zero-code:** compose upstream components only. No `.py` / `.sh` / invented bloblang. The only Welkin-authored logic is the existing canonicalization `mapping` in `gate-2/collector/streams/input.yaml` and the CloudEvents JSON-schema validation — both already present, do not expand.
- **OpenMeter = untrusted SaaS sink.** Collector reaches OpenMeter *only* via its uniform ingest API. Never depend on OpenMeter internals (its Kafka topics, ClickHouse, sink workers).
- **Archive fed by Collector fan-out**, not by OpenMeter — so it is portable to all OpenMeter flavors (self-hosted or managed).
- **AGENTS.md rule 3:** planes share the event, not failure fate — Collector buffers/retries each sink independently; Archive death must not affect Economic processing.
- **Fixed terminology:** Economic Plane, Archive Plane, OpenMeter Collector, Canonical CloudEvent, Welkin. Do not rename.
- **No scope creep:** only the four file changes below + verification + records. Do not add features, extra sinks, or metrics.

---

### Task 1: Collector fans out to our Kafka topic

**Files:**
- Modify: `gates/gate-2/collector/streams/output.yaml`

**Interfaces:**
- Consumes: canonical CloudEvent delivered via `inproc: openmeter` from `input.yaml` (unchanged).
- Produces: same canonical event delivered to OpenMeter API **and** published to Kafka topic `welkin_canonical` (consumed by Task 2's Archive pipeline).

- [ ] **Step 1: Replace the single `openmeter` output with a `broker` fan-out**

Current `output.yaml` ends with:
```yaml
output:
  openmeter:
    url: "${OPENMETER_URL:https://openmeter.cloud}"
    token: "${OPENMETER_TOKEN:}"
    batching:
      count: ${BATCH_SIZE:1}
      period: ${BATCH_PERIOD:30s}
```
Replace the `output:` block with:
```yaml
output:
  broker:
    pattern: fan_out
    outputs:
      - openmeter:
          url: "${OPENMETER_URL:https://openmeter.cloud}"
          token: "${OPENMETER_TOKEN:}"
          batching:
            count: ${BATCH_SIZE:1}
            period: ${BATCH_PERIOD:30s}
      - kafka:
          addresses: [kafka:9092]
          topic: welkin_canonical
          client_id: welkin-collector
```

- [ ] **Step 2: Verify it is valid Redpanda Connect config (lint)**

Run: `docker run --rm -v "$PWD/gates/gate-2/collector:/etc/collector:ro" ghcr.io/openmeterio/benthos-collector:latest streams --log.level error /etc/collector/streams/output.yaml 2>&1 | head -20`
Expected: no parse/lint error (it may try to connect and warn, but config must parse). If a lint error appears, fix the YAML and re-run.

- [ ] **Step 3: Commit**

```bash
git add gates/gate-2/collector/streams/output.yaml
git commit -m "feat(collector): fan out canonical events to OpenMeter API and welkin_canonical topic"
```

### Task 2: Archive Plane consumes our topic (not OpenMeter internals)

**Files:**
- Modify: `gates/gate-3/archive/archive.yaml`

**Interfaces:**
- Consumes: Kafka topic `welkin_canonical` (published by Collector, Task 1).
- Produces: Parquet objects in MinIO bucket `welkin-archive` (verified in Task 5).

- [ ] **Step 1: Change the consumed topic**

In `gates/gate-3/archive/archive.yaml`, change:
```yaml
    topics: [om_default_events]
```
to:
```yaml
    topics: [welkin_canonical]
```

- [ ] **Step 2: Confirm config still parses**

Run: `docker run --rm -v "$PWD/gates/gate-3/archive:/etc/archive:ro" ghcr.io/openmeterio/benthos-collector:latest run --log.level error /etc/archive/archive.yaml 2>&1 | head -20`
Expected: no lint error; it may log "connecting to kafka" — config parsed.

- [ ] **Step 3: Commit**

```bash
git add gates/gate-3/archive/archive.yaml
git commit -m "fix(archive): consume welkin_canonical published by Collector (portable to SaaS OpenMeter)"
```

### Task 3: Gate 3 compose includes the Collector

**Files:**
- Modify: `gates/gate-3/docker-compose.yaml`

**Interfaces:**
- Consumes: `gate-2/docker-compose.yaml` (which `include`s the OpenMeter quickstart + defines the Collector service).
- Produces: a single `up -d` that brings up Collector + OpenMeter (test sink) + Kafka + MinIO + Archive.

- [ ] **Step 1: Point the include at Gate 2 (Collector + quickstart) instead of the quickstart alone**

Replace the `include:` block in `gates/gate-3/docker-compose.yaml`:
```yaml
include:
  - ${OPENMETER_REPO:-../openmeter}/quickstart/docker-compose.yaml
```
with:
```yaml
include:
  - ../gate-2/docker-compose.yaml
```
(The Collector service already sets `OPENMETER_URL: http://openmeter:8888`, so locally it points at the self-hosted OpenMeter from the quickstart. For prod, only `OPENMETER_URL`/`OPENMETER_TOKEN` change.)

- [ ] **Step 2: Confirm compose parses**

Run: `OPENMETER_REPO=../openmeter docker compose -f gates/gate-3/docker-compose.yaml config >/dev/null && echo OK`
Expected: `OK` (no merge/parse error).

- [ ] **Step 3: Commit**

```bash
git add gates/gate-3/docker-compose.yaml
git commit -m "chore(gate-3): include Collector + quickstart; drop duplicate quickstart include"
```

### Task 4: Delete locally-invented code (never pushed)

**Files:**
- Delete (local only, on branch `wip/gate-2-gate-3`): `gates/gate-3/verify.py`, `gates/gate-3/archive/seeder.yaml`, `gates/gate-3/archive/config.yaml`, `gates/gate-2/load/run.py`, `gates/gate-3/.evidence.json`

**Interfaces:** none — cleanup only. The remote `gate-2-gate-3-clean` branch already excludes these.

- [ ] **Step 1: Remove invented files from the local WIP backup branch**

```bash
git checkout wip/gate-2-gate-3
git rm gates/gate-3/verify.py gates/gate-3/archive/seeder.yaml gates/gate-3/archive/config.yaml gates/gate-2/load/run.py gates/gate-3/.evidence.json
git commit -q -m "chore: delete invented harness (verify.py, seeder, run.py) — zero-code repo"
git checkout gate-2-gate-3-clean
```

- [ ] **Step 2: Confirm they are gone from working tree**

Run: `ls gates/gate-3 gates/gate-2/load 2>&1`
Expected: no `verify.py`, `seeder.yaml`, `config.yaml`, `run.py`, `.evidence.json` present.

### Task 5: End-to-end verification (zero code, upstream CLIs)

**Files:** none modified — verification only.

**Interfaces:**
- Consumes: running stack from Task 3.
- Produces: evidence that (a) OpenMeter meters the Collector's events (Economic Plane) and (b) Parquet lands in MinIO from `welkin_canonical` (Archive Plane), plus decoupling proof.

- [ ] **Step 1: Bring up the stack**

```bash
OPENMETER_REPO=../openmeter docker compose -f gates/gate-3/docker-compose.yaml up -d
```

- [ ] **Step 2: Create our topic (upstream CLI)**

```bash
docker compose -f gates/gate-3/docker-compose.yaml exec kafka kafka-topics --create --topic welkin_canonical --bootstrap-server kafka:9092 --partitions 1 --replication-factor 1
```
Expected: `Created topic welkin_canonical` (ignore "already exists").

- [ ] **Step 3: Seed via Collector (upstream API, no code)**

```bash
for i in $(seq 1 5); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/api/v1/events \
    -H 'content-type: application/json' \
    -d "{\"customer\":\"cust-$i\",\"op\":\"GET\",\"route\":\"/\",\"duration_ms\":$i}"
done
```
Expected: five `204` (Collector accepted + canonicalized).

- [ ] **Step 4: Economic proof — OpenMeter received + metered**

OpenMeter does NOT auto-create meters; define them first:
```bash
curl -s -X POST http://localhost:48888/api/v1/meters -H 'content-type: application/json' \
  -d '{"key":"api_requests_total","name":"API Requests","eventType":"request","aggregation":"COUNT"}'
curl -s -X POST http://localhost:48888/api/v1/meters -H 'content-type: application/json' \
  -d '{"key":"api_requests_duration","name":"API Duration","eventType":"request","valueProperty":"$.duration_ms","aggregation":"SUM"}'
curl -s "http://localhost:48888/api/v1/meters/api_requests_total/query?from=2020-01-01T00:00:00Z&to=2030-01-01T00:00:00Z" | head -c 400
```
Expected: JSON containing a `value` > 0 (OpenMeter aggregated the Collector's events).

- [ ] **Step 5: Archive proof — Parquet in MinIO from our topic**

`aws_s3` does NOT auto-create buckets; create it first:
```bash
mc alias set local http://localhost:9000 minioadmin minioadmin
mc mb -p local/welkin-archive
mc ls local/welkin-archive/events/
```
Expected: one or more `events/*.parquet` objects (Collector fan-out → Kafka → Archive → MinIO).

- [ ] **Step 6: Decoupling proof (rule 3)**

```bash
docker compose -f gates/gate-3/docker-compose.yaml stop archive
curl -s -o /dev/null -X POST http://localhost:8080/api/v1/events -H 'content-type: application/json' -d '{"customer":"cust-decouple","op":"GET","route":"/","duration_ms":9}'
docker compose -f gates/gate-3/docker-compose.yaml start archive
sleep 15
mc ls local/welkin-archive/events/
```
Expected: new Parquet object appears after `archive` restarts — planes share the event, not failure fate.

- [ ] **Step 7: Tear down**

```bash
docker compose -f gates/gate-3/docker-compose.yaml down -v
```

### Task 6: Records + publish

**Files:**
- Create: `gates/gate-3/gate-3.md`
- Create: `gates/gate-2/collector/README.md`
- Modify: `gates/gate-2.md` (append Collector-portability note, optional)

**Interfaces:** documentation only.

- [ ] **Step 1: Write `gates/gate-3/gate-3.md`**

Content: Archive Plane consumes `welkin_canonical` (Collector-published), decoupled from OpenMeter; verification evidence (Parquet object count before/after decoupling, Economic `value` > 0); note portability to managed OpenMeter because archive is Collector-fed, not OpenMeter-internal.

- [ ] **Step 2: Write `gates/gate-2/collector/README.md`**

Content: "The Collector is the Welkin production artifact. It is OpenMeter's `benthos-collector`; it canonicalizes raw producer JSON to a Canonical CloudEvent and fans out to the OpenMeter API (Economic Plane) and our `welkin_canonical` Kafka topic (Archive Plane). It works for self-hosted AND managed/SaaS OpenMeter identically — only `OPENMETER_URL`/`OPENMETER_TOKEN` change. OpenMeter is an untrusted SaaS sink; we never depend on its internals."

- [ ] **Step 3: Commit + push the clean branch**

```bash
git add gates/gate-3/gate-3.md gates/gate-2/collector/README.md
git commit -m "docs(gates): record collector-first archive proof + collector portability"
git push origin gate-2-gate-3-clean
```
Expected: push succeeds; remote branch contains only composition + docs, no code.
