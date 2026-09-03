# T5 Network and Dependency Audit

This audit closes the static part of T5-16 through T5-19. It does **not** claim
runtime reachability; the final T5 PASS still requires the ephemeral Kind run.

## T5-16 - Kyverno admission path

The T5 workload default-deny is intentionally scoped to `welkin-system` and
`openmeter-system`. The `kyverno` namespace is outside that selector, so the
Kyverno admission controllers are not accidentally placed behind the Welkin
workload deny policy.

Kyverno remains responsible for its own admission webhook lifecycle and policy
semantics. The bundle keeps Kyverno as an explicit platform controller in the
`kyverno` namespace, with its upstream chart configuration and no custom Cilium
replacement policy graph.

This is deliberate: Cilium workload isolation protects the application trust
domains; Kyverno's Kubernetes admission path remains owned by Kyverno.

**Status: CLOSED - static audit. Runtime: UNVERIFIED.**

## T5-17 - Strimzi/Kafka connectivity

The Welkin Kafka cluster is in `welkin-system`, so Cilium workload default-deny
applies to it. The two application clients have explicit Cilium egress to the
Strimzi Kafka TLS listener on TCP/9093:

| Source | Destination | Port | Purpose |
| --- | --- | --- | --- |
| Collector | Welkin Kafka | 9093/TCP | canonical event production |
| Archive | Welkin Kafka | 9093/TCP | canonical event consumption |

Strimzi 0.45's native network-policy generation remains enabled by default and
owns the Kafka listener/control-plane policy objects. We intentionally do not
replace that graph with hand-authored broker/operator policies. Strimzi also
creates the network policy resources for Kafka and Entity Operator components.

The Kafka listener is internal + TLS, and Kafka ACLs remain separately owned by
Strimzi `KafkaUser` resources. Cilium therefore provides the L3/L4 reachability
boundary while Strimzi owns Kafka-native listener and authorization semantics.

**Status: CLOSED - static audit. Runtime: UNVERIFIED.**

## T5-18 - Application dependency graph

The checked-in graph has these required dependency edges:

```text
Cilium
|-- Kyverno
|-- Strimzi
|-- Postgres
`-- MinIO

Postgres -> OpenMete
OpenMeter + Strimzi -> Collecto
Strimzi + MinIO -> Archive
```

The corresponding runtime network edges are:

```text
Collector --8080--> OpenMete
Collector --9093--> Welkin Kafka
Archive   --9093--> Welkin Kafka
Archive   --9000--> MinIO
OpenMeter --5432--> Postgres
OpenMeter --9092--> its own internal Kafka
```

The last edge is intentionally inside `openmeter-system`; OpenMeter has no
KafkaUser on `welkin-kafka` and no Cilium exception to the Welkin canonical bus.

The base Cilium policy supplies DNS and Kubernetes API access, while the
workload-specific policies supply only the application data-plane edges above.
No new policy is introduced merely to make the audit pass.

**Status: CLOSED - static audit. Runtime: UNVERIFIED.**

## T5-19 - KafkaUser readiness

Both workload KafkaUsers are declared in `platform/infra/strimzi/kafka-users.yaml`.
The T5 workflow now waits explicitly for both resources to report `Ready` before
application deployment:

- `welkin-collector-kafka`
- `welkin-archive-kafka`

The workflow also waits for `welkin-kafka` and `welkin_canonical` readiness first,
so application startup cannot race Kafka/User Operator reconciliation.

**Status: CLOSED - implementation + static verification. Runtime: UNVERIFIED.**

## T5-20 - Exact event identity

Kafka event detection now parses each returned Kafka message as JSON and compares
`message.id == event_id`. It no longer uses substring matching such as
`grep '"id":"...'`.

OpenMeter already performs a structured JSON comparison against `.event.id`, and
the Parquet probe compares the typed `id` column. The same canonical CloudEvent
`id` therefore remains the identity check at all three evidence points.

Malformed/non-JSON probe output is ignored rather than treated as a match, and a
match is accepted only when the top-level JSON `id` field equals the requested
ID exactly.

**Status: CLOSED - implementation. Runtime: UNVERIFIED.**

## Upstream basis

- Cilium policy enforcement is whitelist-based once an endpoint is selected by
  an ingress/egress policy.
- Kyverno admission controllers receive Kubernetes API-server webhook callbacks.
- Strimzi 0.45 generates native NetworkPolicy resources for Kafka listeners and
  other managed components unless custom policy generation is disabled.

The audit intentionally follows those upstream ownership boundaries instead of
creating a second policy/control-plane implementation.

## T5-21 through T5-25 readiness notes

The remaining T5 certification mechanics are intentionally runtime-oriented. The archive probe enumerates all `events/` objects through the S3 paginator and reads only the Parquet `id` column, so certification is not silently limited to the first ListObjectsV2 page and does not deserialize unrelated payload columns. The probe uses the same archive S3 credentials and the archive network identity only where Kafka reachability is required; it does not grant additional RBAC.

The T5 collector probe uses the actual ingestion Service port-forward and expects HTTP 405 to a GET on `/api/v1/events`, because the collector endpoint is POST-only. This proves the forwarded endpoint is reachable without generating a test event merely to establish port-forward readiness. The port-forward binds explicitly to loopback and is terminated on cleanup.

MinIO outage confirmation requires both Deployment `spec.replicas=0` and an empty EndpointSlice. Recovery restores the original replica count, waits for MinIO health, unsuspends the HelmRelease, waits for its Ready condition, and verifies healthy endpoints again. Cleanup executes through the EXIT trap and attempts to release a test-only HelmRelease suspension even if scaling or recovery fails.

**Status: T5-21 CLOSED - bounded Parquet identity scan hardened.**

**Status: T5-22 CLOSED - causal-proof scope explicit; no direct negative object-store query is claimed.**

**Status: T5-23 CLOSED - collector port-forward lifecycle/readiness hardened. Runtime: UNVERIFIED.**

**Status: T5-24 CLOSED - outage injection mechanism hardened and confirmation requires zero replicas plus zero endpoints. Runtime: UNVERIFIED.**

**Status: T5-25 CLOSED - recovery and cleanup hardened with post-unsuspend readiness verification. Runtime: UNVERIFIED.**
