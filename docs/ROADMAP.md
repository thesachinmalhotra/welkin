# Welkin — Production Roadmap / Continuation Checkpoint

## Current DNA
Welkin is a zero-code substrate/composition layer, not a product implementation.

Core flow: `Welkin → OpenMeter Collector → Canonical CloudEvent → Economic Plane + Archive Plane`

Economic: `Canonical CloudEvent → OpenMeter → native Stripe → Invoice`

Archive: `Canonical CloudEvent → Collector broker fan_out → Kafka durable handoff → Archive consumer → Parquet → Object Storage`

Rules: canonicalize once then fan out; OpenMeter owns economic semantics; Kafka is the durable archive handoff; object storage is archive persistence; Parquet is the archive representation; Flux owns reconciliation; OCI digest is exact production identity; prefer upstream capabilities over custom Welkin runtimes.

## Execution discipline
One active node at a time. Finish → verify → checkpoint → next node. Do not jump ahead.

Truth labels: PASS = fresh evidence; UNVERIFIED = implementation exists but runtime evidence is unavailable; FAIL = evidence demonstrates a defect. Never turn UNVERIFIED into PASS by assumption.

## Current state — 2026-09-02
Branch: `gate-2-gate-3-clean`
Latest Welkin checkpoint: `aff790a` (T5 implementation checkpoint)
Current working-tree change: `M certification-e2e/run.sh` (pre-existing T4 work; preserve it).

Completed/checkpointed: Gate 1 OpenMeter smoke; Gate 2 canonicalization; Gate 3 Economic + Archive composition/evidence; durable Kafka/S3 handoff without `drop_on`; T4 consumer-group lag/offset probe implementation.

T5 files: `certification-e2e/t5-archive-outage.sh`, `.github/workflows/t5-archive-outage.yaml`.

## T5 — ACTIVE
Goal: prove Object Storage outage does not destroy the canonical event or stop Economic, and Archive recovers from Kafka after storage returns.

Required proof: baseline event reaches Kafka + Economic; storage unavailable; distinct event reaches Kafka; Archive lag becomes positive; Economic remains functional; event is not persisted during outage; storage restored; event persists to Parquet; lag returns to zero; evidence artifact exists.

Status: IMPLEMENTED / RUNTIME UNVERIFIED.

Important: current T5 implementation uses Kubernetes MinIO scale-to-zero as failure injection. Review this mechanism against the final failure-injection policy before declaring certification PASS. Do not change it while working on another node.

GitHub Actions workflow expects a GitHub Environment containing `WELKIN_KUBECONFIG_B64`. `workflow_dispatch` requires the workflow to be on the default branch for normal manual dispatch.

## Road to production — strict order

### T5 — Object Storage outage certification
ACTIVE. Obtain real runtime evidence. If failure injection needs correction, fix only T5, verify, checkpoint. Do not move forward until PASS.

### T6 — Production storage/profile hardening
BLOCKED until T5 PASS.
Finalize production-only composition values: persistent Kafka storage; broker count/replication; storage classes/sizing; PostgreSQL persistence/backup; object-storage endpoint/bucket/retention; resource sizing; availability; production networking/ingress. Keep dev/certification profiles lightweight and do not inherit dev-only ephemeral assumptions.

### T7 — Protected release pipeline
BLOCKED until T6 PASS.
Prove: `Git commit → render → OCI artifact → immutable digest → certification → signature/provenance → promotion`. Never rebuild after certification. Production identity is the exact OCI digest. Keep production secrets protected and out of plaintext artifacts. Establish staging/production environment boundaries as needed.

### T8 — Staging deployment/rehearsal
BLOCKED until T7 PASS.
Deploy the exact candidate digest through Flux into a production-like environment. Run the complete certification suite and operational checks against that exact artifact.

### T9 — Production readiness gate
BLOCKED until T8 PASS.
Verify Flux reconciliation; secrets; TLS/ACL/network policy; Kafka/PostgreSQL/object-storage persistence and backup posture; monitoring/alerting; rollback/recovery procedure.

### T10 — Production promotion
BLOCKED until T9 PASS.
Promote the same certified OCI digest to production. Flux reconciles it. Do not rebuild.

### T11 — Production smoke + observe
BLOCKED until T10 PASS.
Verify canonical ingestion, OpenMeter economic path, Kafka handoff, Parquet archive, consumer lag, Flux/Kubernetes health, and Stripe/invoice path where applicable. Observe before declaring go-live.

## Final algorithm
`CERTIFIED DIGEST → production approval → same digest → Flux → Kubernetes → Economic + Archive → observe/reconcile`

The objective is not to build more Welkin. It is to prove and safely operate the composition already designed.

## New-chat handoff
Paste this into a new ChatGPT session:

> Continue Welkin from `docs/ROADMAP.md` and the current Git state. Treat the roadmap as the execution order and the repo as implementation source of truth. One active node at a time: finish, verify, checkpoint, then move forward. Do not restart the architecture discussion. Current active node is T5. Read Git status and relevant files first. T5 is implemented but runtime UNVERIFIED. Do not mark it PASS without fresh evidence. Do not jump to T6 until T5 is genuinely PASS.

## Git safety
Before switching nodes: `git status --short`; inspect `git diff`; run node-specific verification; commit the node checkpoint; optionally push for remote backup. Never use destructive reset/clean commands without checking what would be lost.
