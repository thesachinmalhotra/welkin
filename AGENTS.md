# Welkin — Agent Context

## North Star

**Read and obey [`NORTHSTAR.md`](NORTHSTAR.md) before any work.**
It defines the composition-first rule, the non-negotiables, and the gate
discipline that override implementation preferences. When in doubt: compose,
don't build — and prove it at runtime, don't assume it.

## Identity

Welkin is a composition-first, cloud-native usage substrate for usage-based systems.

Welkin is infrastructure, not a business billing product and not a data lake. It composes proven upstream primitives into one coherent, distributable platform.

Welkin does nothing at runtime. It is dependent on upstream components — that is why it is called a **substrate**, not a platform. Every runtime behavior comes from an upstream system. Welkin only configures the composition.

The governing philosophy is:

**Compose, don't build.**

Prefer upstream-native components, open standards, and clean composition over custom infrastructure.

When native upstream and existing implementation conflict, **choose native upstream every time.** Delete, replace, make extinct — no attachment to existing code.

---

## Architecture

Welkin has one canonical event boundary:

```text
Producers
    │
    ▼
OpenMeter Collector
    │
    ▼
Canonical CloudEvent
    │
    ├───────────────┐
    ▼               ▼
Economic Plane   Archive Plane
```

Producer diversity is allowed before canonicalization.

Once an event becomes a canonical CloudEvent, downstream processing is producer-agnostic.

The canonical CloudEvent is the platform contract.

### Economic Plane

```text
Canonical CloudEvent
        │
        ▼
OpenMeter
        │
        ▼
Stripe
```

The Economic Plane handles real-time usage metering, aggregation, entitlements, billing, payment execution, and taxation through the appropriate upstream systems.

The Economic Plane is optimized for latency, correctness, and continuous availability.

### Archive Plane

```text
Canonical CloudEvent
        │
        ▼
Parquet
        │
        ▼
Object Storage
```

The Archive Plane is append-oriented and exists for historical retention, analytics, replay when desired, reporting, and future data workloads.

Archive processing must never become a dependency of the Economic Plane.

Archive failure must not block runtime/economic processing.

The archive is deliberately independent so it can evolve without changing the billing path.

---

## Production Collector Boundary

**OpenMeter Collector is Welkin's production collector.**

It is OpenMeter's published Benthos/Redpanda Connect-based collector distribution.

Vanilla Redpanda Connect is NOT Welkin's production runtime.

`rpk connect test` is test tooling used to exercise and validate compatible collector mappings/processors. It is not the production Collector and must never be treated as a replacement for OpenMeter Collector.

When working on collector behavior, preserve this distinction.

### Collector Architecture

The OpenMeter Collector is a Redpanda Connect distribution with a native `openmeter` output. Welkin configures it — it does not extend it.

```text
Input (Redpanda Connect connector)
    │
    ▼
Pipeline (Bloblang mapping → canonical CloudEvent)
    │
    ▼
Output (native openmeter → OpenMeter API)
```

**65+ upstream inputs available** — any Redpanda Connect connector can be a Welkin event source:

| Category | Examples |
|----------|----------|
| Databases | PostgreSQL CDC, MySQL CDC, MongoDB CDC, CockroachDB CDC, Oracle CDC, SQL Server CDC |
| Message Queues | Kafka, NATS, MQTT, Pulsar, RabbitMQ, Redis Streams |
| Cloud | AWS S3/Kinesis/SQS, Azure Blob/Queue, GCP PubSub/BigQuery |
| Network | HTTP Server, WebSocket, OpenTelemetry gRPC/HTTP |
| Local | File, CSV, Parquet |
| Streaming | Redpanda, Schema Registry |

**2 upstream presets ship in the Helm chart:**
- `http-server` — generic HTTP ingestion with event buffering
- `kubernetes-pod-exec-time` — Kubernetes pod resource metering

Additional sources use the chart's `config` field with standard Redpanda Connect configuration. The native `openmeter` output is built into every configuration — it is not something Welkin adds.

The collector's `preset` field selects an upstream preset. The `openmeter.url` and `openmeter.token` fields configure the native output. Welkin passes these via CUE and environment variables. No custom Benthos config. No processor_resources. No output_resources.

---

## Platform Distribution

Welkin separates what the platform IS from what a particular environment supplies.

```text
             Platform Distribution
                      │
             ┌────────┴────────┐
             ▼                 ▼
       Platform State    Environment State
        immutable          mutable
        versioned       per-environment
             │                 │
             └────────┬────────┘
                      ▼
                    Timoni
                      │
                     OCI
                      │
                    Flux
                      │
                 Kubernetes
```

### Platform State

Platform State defines the Welkin composition:

* component versions
* module graph
* CloudEvent contract
* topology
* platform configuration
* distribution identity

It is immutable and versioned as part of a Welkin release. In the repository it
lives in `platform/product.cue` (versions, product semantics, defaults), the
bundle files (topology), and `spec/` (contracts). It is never runtime-injected.

The Welkin platform, rather than individual upstream components, is the compatibility boundary.

### Environment State

Environment State contains values unique to a deployment environment:

* credentials and secrets
* environment-specific endpoints
* storage locations
* enabled producers
* capacity/scaling choices
* other deployment-specific configuration

Environment State must not redefine what a Welkin release fundamentally is.

Do not confuse Welkin's Environment State with the Economic Plane. Timoni's Runtime API is a distribution/configuration mechanism; "Runtime" must not be used as a replacement for the Welkin plane name.

---

## Timoni → OCI → Flux

Timoni is the primary Welkin distribution surface.

A Welkin release is packaged as an OCI artifact representing a tested platform composition.

Semantic versions communicate human-readable release intent.

OCI digests provide immutable artifact identity.

Flux consumes and reconciles the Welkin OCI artifact into Kubernetes.

Development and release references may use appropriate SemVer selection, while released deployments should ultimately resolve to immutable artifact identities.

Do not treat individual component versions as independent Welkin compatibility boundaries.

---

## Implementation Is Not Architecture

Welkin's architectural invariants and intent are authoritative; the current implementation is not.

Agents MUST NOT treat existing file layouts, abstractions, paths, configuration mechanisms, or implementation choices as architectural constraints merely because they already exist.

When solving a problem:

- Preserve the established architectural invariants and product intent.
- Research the current upstream-native primitives available from Timoni, Flux, Helm, Kubernetes, OpenMeter, and other components already in the architecture.
- Evaluate multiple viable implementation paths when the current implementation creates friction.
- Prefer the most technically elegant, upstream-native, minimal-composition solution available today.
- Do not introduce Welkin-specific machinery merely to preserve an existing implementation.
- Existing implementation may be replaced, simplified, relocated, or removed when doing so better satisfies the architecture.

Rule of thumb: **protect the DNA, not the machinery.**

---

## Architectural Invariants

These are non-negotiable unless an explicit architectural decision changes them:

1. Canonical CloudEvents are the platform contract.
2. Producer diversity ends at canonicalization.
3. Economic and Archive planes are independent.
4. Archive processing must never block Economic Plane processing.
5. OpenMeter Collector is the production collector.
6. `rpk` is test tooling, not production runtime.
7. Platform State and Environment State remain separate.
8. Timoni → OCI → Flux is the platform distribution model.
9. The Welkin platform is the compatibility boundary.
10. Prefer composition over custom services.
11. Prefer open standards and upstream-native capabilities.
12. Do not introduce infrastructure merely because building it is convenient.
13. Do not redesign established architecture to solve a local implementation inconvenience.
14. Do not silently expand scope.
15. Welkin owns no security or runtime mechanism — every concern maps to a
    native upstream owner (see the concern→owner table in docs/architecture.md).

---

## Current Scope

Welkin's core value is the substrate:

**canonical ingestion → real-time economic processing + durable archive → independently composable downstream analytics.**

The archive provides a versatile durable event foundation without making analytics infrastructure part of the billing path.

Do not turn Welkin into a monolithic billing platform or monolithic data platform.

Future extensions may build on the archive, but extensions are not the reason to complicate the core runtime.

---

## Engineering Principles

When implementing:

* Research authoritative upstream behavior when integration semantics are uncertain.
* Prefer current upstream documentation/source over assumptions or stale examples.
* Preserve existing architectural decisions unless new evidence genuinely requires reconsideration.
* Make small, controlled, reversible changes.
* Keep platform semantics separate from environment configuration.
* Keep production configuration separate from test harness configuration.
* Test the behavior that actually runs in production.
* Do not weaken production behavior merely to make an isolated test convenient.
* Keep CI, release, and deployment behavior reproducible.
* Treat Git history and CI results as evidence, not agent summaries.
* Inspect actual diffs before reverting or rewriting existing work.
* Avoid unrelated cleanup during focused iterations.

---

## Repository Authority

When sources disagree, use this priority:

1. Architecture: canonical invariants and Welkin intent (this file, architecture/contract docs)
2. Current upstream authoritative documentation/source
3. Actual current implementation and tests — evidence and context, never authority
4. Historical plans and notes
5. Agent assumptions

Historical plans may describe earlier repository layouts and must not override the current architecture.

Before changing a component integration, inspect the current implementation and relevant upstream artifact/version.

---

## Agent Working Protocol

Before implementing a non-trivial change:

1. Inspect the current repository and Git state.
2. Understand which architectural boundary the change belongs to.
3. Research upstream behavior when necessary.
4. State the intended scope.
5. Make the smallest coherent change.
6. Run relevant validation.
7. Inspect the final diff.
8. Report what changed, what was verified, and what remains.

For focused iterations:

**Do not start later work while the current iteration is unresolved.**

If a discovery appears unrelated to the current task, record it rather than expanding scope.

If the repository contains conflicting state or an uncommitted change, stop and inspect it before modifying anything.

---

## Engineering Process

These conventions apply to all contributors — humans and AI agents.

### Commits

Every commit must follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>
```

**Types:** `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`

**Scopes:** `cert`, `openmeter`, `collector`, `flux`, `timoni`, `ci`, `certification`, `contracts`

**Rules:** subject max 72 chars, no period, imperative mood, no `@latest`.

Enforced by `.commitlintrc.json` and `.pre-commit-config.yaml`.

### Before pushing

1. Run relevant local validation (CUE vet, timoni bundle vet, Python compile check).
2. No CI run until local checks are green.
3. Follow the PR template (`.github/PULL_REQUEST_TEMPLATE.md`).

### File organization

| Path | What lives here |
|---|---|
| `AGENTS.md` | Architecture, invariants, agent instructions |
| `spec/schema/` | Canonical CloudEvent and archive schemas |
| `platform/bundles/` | Platform composition (Timoni bundles) |
| `platform/runtime/` | Runtime contracts (Platform State) |
| `platform/economic/` | Economic plane components (OpenMeter, Postgres) |
| `platform/archive/` | Archive plane components (MinIO) |
| `platform/collector/` | Collector component values |
| `spec/meters/` | Meter catalog (wired into OpenMeter config) |
| `.github/workflows/` | CI workflows |

### What NOT to do

- Do not add custom services, controllers, or SDKs.
- Do not embed infrastructure manifests in Python scripts.
- Do not hardcode credentials in Platform State.
- Do not use `@latest` or unpinned versions.
- Do not bypass the collector boundary (always POST to `:8080/api/v1/events`).
- Do not commit secrets, tokens, or keys.

---

## Current Maturity

Welkin is **Alpha**.

The end-to-end architecture is established and stable.

Implementation is catching up to the architecture.

Alpha status means implementation, operational hardening, certification, and interfaces may still evolve. It does NOT mean the architecture should be casually redesigned.

The goal is to make the established architecture increasingly complete, reproducible, operable, and polished.

---

## Agent Mindset

You are an implementer and researcher working within an established platform direction.

**Do not become the architect by accident.**

Use fresh upstream research and repository evidence to improve implementation, but preserve Welkin's established vocabulary, boundaries, and philosophy.

When evidence conflicts with an existing architectural decision:

**surface the conflict before changing the architecture.**

When there is no conflict:

**implement cleanly and move forward.**

**Compose, don't build.**
