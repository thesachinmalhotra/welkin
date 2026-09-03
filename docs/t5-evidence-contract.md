# T5 Evidence Contract

T5 certifies one failure boundary only: Object Storage is unavailable while the canonical event remains durable in Kafka, Economic remains functional, and Archive recovers after storage returns.

## PASS evidence

A T5 PASS artifact must record fresh runtime evidence for all of the following:

1. A unique baseline event was accepted and observed in both Kafka and OpenMeter before the outage.
2. Object Storage became unavailable.
3. A distinct outage event was accepted and observed in both Kafka and OpenMeter while Object Storage was unavailable.
4. The `welkin-archive` consumer group had positive lag during the outage.
5. Object Storage recovered.
6. The exact outage event ID was subsequently observed in Parquet, using the CloudEvent `id` field as the canonical identity.
7. The `welkin-archive` consumer group returned to zero lag.
8. Runtime temporal evidence establishes that the outage event could not have been persisted while Object Storage was confirmed unavailable: the event was accepted only after outage confirmation, and its archive observation occurred after recovery.

## Artifact

`certification.json` records the run timestamps, Kubernetes context/namespace, both event IDs, and the observed evidence values.

The outage-event non-persistence claim is established by runtime temporal ordering and the failure boundary: Object Storage is confirmed unavailable with the MinIO Deployment scaled to zero and no Service endpoints before the distinct outage event is accepted. The exact event is not queried in storage during the outage; after Object Storage recovery, it is observed in Parquet. Because the tested storage service had zero ready backends during event acceptance, an archive write to that Service could not succeed during the tested interval. This is a boundary proof, not a direct negative object-store query: T5 does not claim to prove the absence of the event in an independent storage system or through an untested alternate write path. The artifact records this scoped claim as `outage_event_not_persisted_during_outage`.

The end-to-end correlation claim does not introduce a Welkin-specific correlation mechanism: the same canonical CloudEvent `id` is checked in Kafka, OpenMeter, and the Parquet `id` column. The artifact records this as `outage_event_id_correlated_end_to_end`.


## Truth labels

- `PASS`: every required observation above has fresh runtime evidence.
- `UNVERIFIED`: implementation exists but runtime evidence is unavailable.
- `FAIL`: runtime evidence demonstrates a defect.

No required observation is inferred from configuration alone.
