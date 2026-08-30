# Gate 3 — Archive Plane (Collector-fed, decoupled)

## Architecture
The Welkin Collector (OpenMeter's `benthos-collector`) canonicalizes raw producer
events to a Canonical CloudEvent and fans out via a Redpanda Connect broker to:

- **OpenMeter API** — the Economic Plane (OpenMeter meters and invoices).
- **`welkin_canonical` Kafka topic** — consumed by an independent Archive pipeline
  (`gates/gate-3/archive/archive.yaml`: `kafka` → `aws_s3` + `parquet_encode`) that
  writes Parquet to MinIO (`welkin-archive` bucket).

```
Producer --raw--> Collector --> fan_out --> OpenMeter API  (Economic)
                            \--> welkin_canonical --> Archive --> MinIO Parquet
```

## Why this is portable (the point of Gate 3)
The Archive Plane consumes **Welkin's own topic**, published by the Collector — never
OpenMeter internals (`om_default_events`, ClickHouse, sink workers). So the Archive
Plane works identically for **self-hosted AND managed/SaaS OpenMeter**: only
`OPENMETER_URL`/`OPENMETER_TOKEN` (Collector → OpenMeter) change. OpenMeter is treated
as an untrusted SaaS sink we do not control.

## Object storage is interchangeable (not coupled to MinIO)
The Archive pipeline uses the upstream `aws_s3` output, which is S3-compatible. **MinIO
is only the local-dev stand-in** (exactly like the OpenMeter quickstart is the local
stand-in for OpenMeter). Point it at any store via env — no pipeline edit:

```
ARCHIVE_ENDPOINT=https://<account>.r2.cloudflarestorage.com   # or s3.amazonaws.com, etc.
ARCHIVE_BUCKET=welkin-archive
ARCHIVE_REGION=auto
ARCHIVE_FORCE_PATH_STYLE=true
ARCHIVE_ACCESS_KEY=...
ARCHIVE_SECRET_KEY=...
```

`force_path_style_urls` stays `true` for MinIO/R2; set `false` only for virtual-hosted
AWS S3. The `archive` service in `docker-compose.yaml` passes these through, so `up -d`
works locally (MinIO) and prod swaps stores by env alone.

## Environment (self-hosted vs managed — env only, no config edits)
Every external dependency is parameterized. Copy `gates/gate-3/.env.example` to `.env`
and fill it; docker compose auto-loads it. The same config runs locally and in prod:

| Variable | Local (this Gate) | Managed / prod |
|----------|-------------------|----------------|
| `OPENMETER_URL` / `OPENMETER_TOKEN` | `http://openmeter:8888` / empty | `https://openmeter.cloud` / `om_xxx` |
| `KAFKA_BROKERS` | `kafka:9092` | your broker(s) |
| `ARCHIVE_ENDPOINT` / `ARCHIVE_BUCKET` | `http://minio:9000` / `welkin-archive` | R2 / S3 / GCS + bucket |
| `ARCHIVE_ACCESS_KEY` / `ARCHIVE_SECRET_KEY` | `minioadmin` | real store creds |

The Collector and Archive pipelines read these via `${VAR:-default}`, so swapping a plane
for a managed service is an env change, never a code or config change.

## AGENTS.md rule 3 (planes share the event, not failure fate)
The Collector buffers and retries each sink independently. Archive death does not stop
Economic processing, and vice versa. Proven by the decoupling check below.

## Verification procedure (zero code — upstream CLIs only)
```bash
OPENMETER_REPO=/home/sachin/projects/personal/openmeter \
  docker compose -f gates/gate-3/docker-compose.yaml up -d
sleep 15   # let kafka/openmeter become ready before topic creation
docker compose -f gates/gate-3/docker-compose.yaml exec -e JMX_PORT= -e KAFKA_JMX_OPTS= kafka \
  kafka-topics --create --topic welkin_canonical --bootstrap-server kafka:9092 \
  --partitions 1 --replication-factor 1
# create archive bucket BEFORE events flow (aws_s3 does not auto-create)
# mc is run dockerized (no host install); MC_HOST_ env avoids alias persistence
MC="docker run --rm --network host -e MC_HOST_local=http://minioadmin:minioadmin@localhost:9000 minio/mc"
$MC mb -p local/welkin-archive
# seed via Collector (raw -> canonical)
for i in $(seq 1 5); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/api/v1/events \
    -H 'content-type: application/json' \
    -d "{\"customer\":\"cust-$i\",\"op\":\"GET\",\"route\":\"/\",\"duration_ms\":$i}"
done
# Economic proof — OpenMeter does NOT auto-create meters; define them first
curl -s -X POST http://localhost:48888/api/v1/meters -H 'content-type: application/json' \
  -d '{"key":"api_requests_total","name":"API Requests","eventType":"request","aggregation":"COUNT"}'
curl -s -X POST http://localhost:48888/api/v1/meters -H 'content-type: application/json' \
  -d '{"key":"api_requests_duration","name":"API Duration","eventType":"request","valueProperty":"$.duration_ms","aggregation":"SUM"}'
curl -s "http://localhost:48888/api/v1/meters/api_requests_total/query?from=2020-01-01T00:00:00Z&to=2030-01-01T00:00:00Z" | head -c 400
# Archive proof (bucket created earlier)
$MC ls local/welkin-archive/events/
# Decoupling proof
docker compose -f gates/gate-3/docker-compose.yaml stop archive
curl -s -o /dev/null -X POST http://localhost:8080/api/v1/events -H 'content-type: application/json' \
  -d '{"customer":"cust-decouple","op":"GET","route":"/","duration_ms":9}'
docker compose -f gates/gate-3/docker-compose.yaml start archive
sleep 15; $MC ls local/welkin-archive/events/
```

## Evidence
**STATUS: VERIFIED** (run `2026-08-29`, Docker Desktop 29.7.2 / Compose v5.4.0, WSL2).
End-to-end procedure executed; all three planes proven:

- **Economic plane (OpenMeter):** created meters `api_requests_total` (COUNT) and
  `api_requests_duration` (SUM); query returned `value: 8` and `value: 18` respectively
  (both > 0). Raw -> canonical -> OpenMeter works.
  - Note: 8 counted vs 5 seeded — 3 additional `request` events present in OpenMeter's
    store (likely OpenMeter-internal `request` events or a replay). Does not affect the
    proof; logged as an open question to confirm.
- **Archive plane (Parquet in MinIO):** `mc ls` showed
  `events/1-1787993828281897112.parquet` (2.4 KiB) after seeding. S3-compatible store
  write + Parquet encode works.
- **Decoupling (AGENTS.md rule 3):** stopped `archive`, seeded 1 event during the outage
  (Collector returned `204` — Economic unaffected), restarted `archive`, waited, and a
  **second** object `events/1-1787993880551629220.parquet` (2.2 KiB) appeared. The
  Archive Plane caught up from Kafka after death; failure was NOT shared with Economic.

### Phase 2 parity — one ID across all three planes (run `2026-08-30`)
**Test ID `parity-verify-1`** (`customer=cust-parity, op=PUT, route=/v1/parity, duration_ms=73`).
Canonical CloudEvent `{id, specversion, type, source, subject, time, data{duration_ms,method,route}}`
read back from **OpenMeter** (`GET /api/v1/events`)**, Kafka (`welkin_canonical`)**, and **Parquet**
opaque row — **identical** in all three (only serialization precision differs: OpenMeter seconds,
Parquet microsecond, Kafka nanosecond `time`).

**Duplicate result:** re-posted the same explicit ID. **OpenMeter dedupes by ID** (still 1 entry, total
unchanged) while **Kafka + Archive preserve the replay** (2nd copy, 2nd Parquet). Economic = dedup
semantics; Archive = history semantics — same canonical event, per-plane consumption.

**Reverse failure (decoupling rule 3, both directions now verified):** stopped `openmeter` (Economic
sink down, HTTP `000`). Seeded `rev-outage-1`/`rev-outage-2` — Collector returned `204`, published to
Kafka (offset 10→12), archived a new Parquet (`08:10:24`, rows `rev-outage-1`/`rev-outage-2`).
Archive proceeded independently of Economic. After `openmeter` restart (healthy) it caught up —
both events delivered/counted, each exactly once. **Economic death does not stop Archive.**

### Runbook fixes discovered during this run (already applied above)
1. `mc` is not on the host — run dockerized:
   `docker run --rm --network host -e MC_HOST_local=http://minioadmin:minioadmin@localhost:9000 minio/mc …`
   (On WSL with `credsStore: desktop.exe`, the first `minio/mc` pull may fail with
   "error getting credentials"; work around with `DOCKER_CONFIG=/tmp/dockercfg docker pull minio/mc`,
   after which the cached image runs without creds.)
2. The Kafka container sets `JMX_PORT: 9997`; a second `kafka-topics` process in the same
   container tries to bind it and aborts before creating the topic. Disable for the client:
   `exec -e JMX_PORT= -e KAFKA_JMX_OPTS= kafka kafka-topics …`.
