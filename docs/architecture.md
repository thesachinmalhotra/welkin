# Welkin Platform — Architecture

Two planes, one contract. The OpenMeter Collector is the only normalization
boundary; everything downstream sees the Canonical CloudEvent.

```
Any producer
    ↓
OpenMeter Collector (benthos-collector)   ← canonicalization, validation, buffer
    ├── Economic Plane → OpenMeter (subject extraction) → Stripe → Invoice
    └── Archive Plane → Kafka (welkin_canonical, 90d retention)
                            → Benthos (welkin-archive) → MinIO/S3 → Parquet (bronze/daily)
```

## Ownership (compose, don't build)

| Layer | Upstream owner |
|-------|----------------|
| Collector | `benthos-collector` chart (openmeterio) |
| Economic | `openmeter` chart + Stripe |
| Archive buffer | Strimzi Kafka (topic `welkin_canonical`, 90d) |
| Archive sink | `benthos-collector` chart (second instance) → MinIO/S3 |
| Network isolation | Cilium (egress denials, NetworkPolicy) |
| Admission guardrails | Kyverno (no ClusterRoleBinding from `openmeter-system`) |
| Labs/datastore | Postgres (cnpg) |
| Secrets at rest | SOPS (age), decrypted by Flux |
| Delivery | keyless cosign-signed OCI artifact (Flux) → OCIRepository `verify.matchOIDCIdentity` → Kustomization |

## Lifecycle

1. `platform/welkin.bundle.cue` — single source (Timoni bundle).
2. CI `build.yaml` — `timoni bundle build` → encrypt secrets (SOPS) → assemble
   Flux artifact directory (`kustomization.yaml` + `welkin.yaml` +
   `welkin-secrets.yaml`) → `kubectl kustomize` validates →
   `flux push artifact --path=/tmp/artifact --output json` → capture digest →
   `cosign sign --yes $DIGEST_URL` (keyless, GHA OIDC).
3. Flux `clusters/dev` — `OCIRepository` verifies digest via
   `verify.matchOIDCIdentity` (not `secretRef`) + `Kustomization` decrypts
   (SOPS `sops-age`) + reconciles `path: "./"`.
4. Promotion — repin `OCIRepository.spec.ref.tag`; no rebuild.
5. `certification-e2e/run.sh` — gate on canonical flow + plane independence
   + OpenMeter isolation.

## Local gates

`gates/` docker-compose runs the SAME collector config, exported via
`make export-gates` from the rendered bundle (no drift from prod).
