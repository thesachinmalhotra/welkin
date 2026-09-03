# Welkin OpenMeter Collector

**This is the Welkin production artifact.** Everything else in the Gates is test
scaffolding or downstream consumption.

## What it is
OpenMeter's own `benthos-collector` (Redpanda Connect distribution), configured by Welkin
to sit in front of any producer.

## What it does (the only Welkin-owned logic)
1. Ingests raw producer JSON at `:8889/api/v1/events` (`streams/input.yaml`).
2. Canonicalizes it to a **Canonical CloudEvent** via the `welkin_canonicalize` mapping
   (the single piece of Welkin-authored transformation).
3. Validates against `cloudevents.spec.json`.
4. Fans out (Redpanda Connect `broker`) to:
   - **OpenMeter API** (`openmeter` output) — the Economic Plane.
   - **`welkin_canonical` Kafka topic** — the Archive Plane source.

## Portable to ANY OpenMeter (self-hosted or managed/SaaS)
The Collector reaches OpenMeter **only via its uniform ingest API**. Switching from
self-hosted to managed OpenMeter changes exactly two values:

```
OPENMETER_URL=https://openmeter.cloud   # was http://openmeter:8888
OPENMETER_TOKEN=<your cloud token>      # was empty
```

No other change. The Collector config is byte-identical.

## OpenMeter is an untrusted SaaS sink
We never depend on OpenMeter internals (its Kafka topics, ClickHouse, sink workers). The
Archive Plane is fed by the Collector's `welkin_canonical` fan-out, so it works even when
we cannot see OpenMeter's internals (managed/SaaS). This satisfies AGENTS.md rule 3:
planes share the event, not failure fate.
