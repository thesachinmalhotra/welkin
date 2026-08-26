# WELKIN ENGINEERING NORTH STAR

Repository: thesachinmalhotra/Welkin

Welkin is a composition layer, not an implementation layer.

Primary rule:

> Before implementing any capability, identify the authoritative upstream ecosystem that already owns that problem and compose its native capability into Welkin.

Welkin must not recreate capabilities already owned by:

- OpenMeter
- Redpanda Connect / OpenMeter Collector
- Kubernetes
- Flux
- Timoni
- GitHub Actions
- OCI registries
- Cosign / Sigstore
- the customer's infrastructure

Canonical architecture:

```
ANY SUPPORTED SOURCE
        ↓
OpenMeter Collector / Redpanda Connect
        ↓
Canonical CloudEvent
        ↓
Welkin fan-out
        ├── Economic Plane → OpenMeter
        └── Archive Plane  → S3-compatible storage / Parquet
```

Distribution:

```
Timoni composition
        ↓
OCI artifact
        ↓
Flux
        ↓
Kubernetes
```

## NON-NEGOTIABLES

1. Do not introduce custom infrastructure to solve an upstream problem.
2. Do not create source-specific Welkin ingestion adapters.
3. Do not create a custom queue, broker, retry controller, deduplication service,
   secret manager, API gateway, auth service, reconciliation controller,
   artifact registry, signing service, or source adapter unless evidence proves
   no authoritative upstream mechanism can satisfy the requirement.
4. Prefer upstream configuration over Welkin implementation.
5. Prefer upstream presets/modules over custom configuration.
6. Prefer Kubernetes-native mechanisms for Kubernetes concerns.
7. Prefer GitHub-native mechanisms for CI/CD concerns.
8. Prefer Timoni runtime state for environment-specific configuration.
9. Never weaken a test merely to make CI green.
10. Never call something "verified" merely because it renders, compiles,
    or is theoretically supported by upstream documentation.
11. Distinguish:
       implemented
       statically validated
       runtime verified
       release certified
12. Do not redesign architecture while diagnosing an implementation failure.
13. Work one production gate at a time.
14. When a gate fails, diagnose and fix that gate only.
15. Do not advance to later gates until the current gate has an explicit
    evidence-backed exit condition.

Before adding code/configuration, answer:

> Which authoritative upstream component owns this capability,
> and why can't its native mechanism satisfy Welkin's requirement?

If there is no convincing answer, do not add the code.
