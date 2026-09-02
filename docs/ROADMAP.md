# Welkin — Production Roadmap / Continuation Checkpoint

## Current DNA
Welkin is a zero-code substrate/composition layer, not a product implementation.

Core flow: 

Economic: 

Archive: 

Rules: canonicalize once then fan out; OpenMeter owns economic semantics; Kafka is the durable archive handoff; object storage is archive persistence; Parquet is the archive representation; Flux owns reconciliation; OCI digest is exact production identity; prefer upstream capabilities over custom Welkin runtimes.

## Execution discipline
One active node at a time. Finish → verify → checkpoint → next node. Do not jump ahead.

Truth labels: PASS = fresh evidence; UNVERIFIED = implementation exists but runtime evidence is unavailable; FAIL = evidence demonstrates a defect. Never turn UNVERIFIED into PASS by assumption.

## Current state — 2026-09-02
Branch: 
Latest Welkin checkpoint:  (T5 implementation checkpoint)
Current working-tree change:  (pre-existing T4 work; preserve it).

Completed/checkpointed: Gate 1 OpenMeter smoke; Gate 2 canonicalization; Gate 3 Economic + Archive composition/evidence; durable Kafka/S3 handoff without ; T4 consumer-group lag/offset probe implementation.

T5 files: , .

## T5 — ACTIVE
Goal: prove Object Storage outage does not destroy the canonical event or stop Economic, and Archive recovers from Kafka after storage returns.

Required proof: baseline event reaches Kafka + Economic; storage unavailable; distinct event reaches Kafka; Archive lag becomes positive; Economic remains functional; event is not persisted during outage; storage restored; event persists to Parquet; lag returns to zero; evidence artifact exists.

Status: IMPLEMENTED / RUNTIME UNVERIFIED.

Important: current T5 implementation uses Kubernetes MinIO scale-to-zero as failure injection. Review this mechanism against the final failure-injection policy before declaring certification PASS. Do not change it while working on another node.

GitHub Actions workflow expects a GitHub Environment containing .  requires the workflow to be on the default branch for normal manual dispatch.

## Road to production — strict order

### T5 — Object Storage outage certification
ACTIVE. Obtain real runtime evidence. If failure injection needs correction, fix only T5, verify, checkpoint. Do not move forward until PASS.

### T6 — Production storage/profile hardening
BLOCKED until T5 PASS.
Finalize production-only composition values: persistent Kafka storage; broker count/replication; storage classes/sizing; PostgreSQL persistence/backup; object-storage endpoint/bucket/retention; resource sizing; availability; production networking/ingress. Keep dev/certification profiles lightweight and do not inherit dev-only ephemeral assumptions.

### T7 — Protected release pipeline
BLOCKED until T6 PASS.
Prove: . Never rebuild after certification. Production identity is the exact OCI digest. Keep production secrets protected and out of plaintext artifacts. Establish staging/production environment boundaries as needed.

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


The objective is not to build more Welkin. It is to prove and safely operate the composition already designed.

## New-chat handoff
Paste this into a new ChatGPT session:

> Continue Welkin from  and the current Git state. Treat the roadmap as the execution order and the repo as implementation source of truth. One active node at a time: finish, verify, checkpoint, then move forward. Do not restart the architecture discussion. Current active node is T5. Read Git status and relevant files first. T5 is implemented but runtime UNVERIFIED. Do not mark it PASS without fresh evidence. Do not jump to T6 until T5 is genuinely PASS.

## Git safety
Before switching nodes:  M src/main/sandbox.ts; inspect diff --git a/src/main/sandbox.ts b/src/main/sandbox.ts
index 84e4e28..8e229a4 100644
--- a/src/main/sandbox.ts
+++ b/src/main/sandbox.ts
@@ -260,16 +260,6 @@ async function normaliseNativePath(roots: readonly Root[], input: string): Promi
     : trimmed.replace(/^\/+/, '');
   const nativeSegments = nativeWindows ? withoutNativeRoot.split(/[/\]+/) : withoutNativeRoot.split(/\/+/);
   for (const segment of nativeSegments.filter((part) => part.length > 0)) checkSegment(segment);
-  // Approved roots categorically reject UNC paths. Do not ask Windows to resolve a network
-  // share merely to discover that it cannot belong to any root: an unreachable host can turn
-  // an immediate sandbox refusal into seconds of blocking DNS/SMB work.
-  if (nativeWindows && trimmed.startsWith('\\')) {
-    const names = roots.map((r) => ).join(', ') || '(none approved)';
-    throw new SandboxError(
-       +
-        
-    );
-  }
   const native = path.resolve(trimmed);
   let canonicalNative: string;
   try {
@@ -464,3 +454,5 @@ export function strayVirtualPath(text: string, roots: readonly Root[]): string |
   }
   return null;
 }
+
+; run node-specific verification; commit the node checkpoint; optionally push for remote backup. Never use destructive reset/clean commands without checking what would be lost.
