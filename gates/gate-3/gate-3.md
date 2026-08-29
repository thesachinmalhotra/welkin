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

## AGENTS.md rule 3 (planes share the event, not failure fate)
The Collector buffers and retries each sink independently. Archive death does not stop
Economic processing, and vice versa. Proven by the decoupling check below.

## Verification procedure (zero code — upstream CLIs only)
```bash
OPENMETER_REPO=/home/sachin/projects/personal/openmeter \
  docker compose -f gates/gate-3/docker-compose.yaml up -d
docker compose -f gates/gate-3/docker-compose.yaml exec kafka \
  kafka-topics --create --topic welkin_canonical --bootstrap-server kafka:9092 \
  --partitions 1 --replication-factor 1
# seed via Collector (raw -> canonical)
for i in $(seq 1 5); do
  curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8080/api/v1/events \
    -H 'content-type: application/json' \
    -d "{\"customer\":\"cust-$i\",\"op\":\"GET\",\"route\":\"/\",\"duration_ms\":$i}"
done
# Economic proof
curl -s "http://localhost:48888/api/v1/meters/api_requests_total/query?from=2020-01-01T00:00:00Z&to=2030-01-01T00:00:00Z" | head -c 400
# Archive proof
mc alias set local http://localhost:9000 minioadmin minioadmin
mc ls local/welkin-archive/events/
# Decoupling proof
docker compose -f gates/gate-3/docker-compose.yaml stop archive
curl -s -o /dev/null -X POST http://localhost:8080/api/v1/events -H 'content-type: application/json' \
  -d '{"customer":"cust-decouple","op":"GET","route":"/","duration_ms":9}'
docker compose -f gates/gate-3/docker-compose.yaml start archive
sleep 15; mc ls local/welkin-archive/events/
```

## Evidence
**STATUS: NOT YET CAPTURED** — the Docker daemon was not running in the environment
where these configs were authored, so the end-to-end run above has not been executed
yet. Run the procedure (Docker Desktop started / WSL integration enabled) to capture:
Parquet object count before/after the decoupling stop/start, and OpenMeter `value` > 0.
