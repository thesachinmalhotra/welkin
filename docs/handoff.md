# Session Handoff

## STATE
Welkin platform defined as a single Timoni bundle + keyless signed/encrypted
Flux delivery. Local gates (gate-2/gate-3 docker-compose) already existed with
recorded e2e evidence. This session built the platform source, the delivery
pipeline, the certification gate, and ran a ponytail-audit cleanup.

## ACTIVE OBJECTIVE
Stand up the full platform on a real cluster and convert INFERENCE → VERIFIED
via `certification-e2e/run.sh`. Prereq: key/secret wiring + flux bootstrap.

## CURRENT GATE
`certification-e2e/run.sh` (canonical flow + plane independence + OpenMeter
isolation). NOT yet run — no cluster has reconciled the bundle.

## MILESTONE
Local architecture gates VERIFIED. Delivery artifact validated locally via
`kubectl kustomize`. Keyless OCI signing path prepared (GHA OIDC,
`matchOIDCIdentity`). Clean-cluster reconciliation remains the next
unverified boundary.

## FACTS
- `timoni bundle lint` + `timoni bundle build` pass (9/9 instances valid).
- No real secret renders inline in the bundle (grep-verified); creds injected
  via `envFrom`/`existingSecret` from SOPS-encrypted Secrets generated at CI.
- Delivery is keyless: `flux push artifact --output json` → digest → `cosign sign`
  (GHA OIDC); Flux verifies via `OCIRepository.spec.verify.matchOIDCIdentity`
  (not `secretRef: cosign-public-key`). Only SOPS age key remains pre-shared.
- Artifact shape is Flux-native:
  `/tmp/artifact/{welkin.yaml,welkin-secrets.yaml,kustomization.yaml}` with
  `path: "./"` (validated locally via `kubectl kustomize`); not a single-file push.

## EVIDENCE
- `timoni bundle lint` output: bundle valid.
- `timoni bundle build` + grep: zero inline secrets, env interpolation present.
- Prior repo: gate-2/gate-3 e2e evidence committed (VERIFIED tag in history).

## CHANGES
- Added: `platform/welkin.bundle.cue`, `platform/infra/{cilium,kyverno,strimzi}/*`,
  `.github/workflows/build.yaml`, `clusters/dev/*`, `certification-e2e/run.sh`,
  `Makefile`, `.sops.yaml`, `docs/architecture.md`, `docs/runbooks/keys.md`, `.gitignore`.
- Removed (audit): `platform/cloudevents.cue`, `clusters/dev/image-automation.yaml`,
  Kyverno `verify-image-signatures` + non-Cilium `add-default-deny-networkpolicy`.
- Canonical contract now lives ONLY in the collector's inline `json_schema`.

## COMMIT/PR
Branch `gate-2-gate-3-clean` (1 commit ahead of origin `c6d6a2b` in audit; latest
HEAD contains the keyless fix). Not yet pushed — awaiting artifact validation.

## TESTS/CI/E2E
- `build.yaml` CI not yet exercised (needs repo secrets: OPENMETER_API_KEY,
  STRIPE_API_KEY, ARCHIVE_S3_*; cosign is keyless — no `COSIGN_PRIVATE_KEY`;
  `GITHUB_TOKEN` + `id-token: write` + `packages: write` supplied by Actions).
- `certification-e2e/run.sh` written but unrun (no cluster).

## ADVERSARIAL RESULT
Not run. Claims of isolation are INFERENCE until the e2e gate executes on a
live cluster. Known risk: chart value fields (envFrom, existingSecret, Strimzi
ACL wiring) are schema-valid but runtime-unproven.

## REGRESSIONS CHECKED
- `timoni bundle lint` re-run after audit cleanup → still valid.
- No dangling references to deleted `cloudevents.cue` (grep clean).

## OPEN QUESTIONS
- `.sops.yaml` + `clusters/dev/secrets.yaml` carry `REPLACE_WITH_AGE_*`
  placeholders for the SOPS age keypair — must be filled before any build/sign
  (see `docs/runbooks/keys.md`).
- Promotion model: dev→prod = repin `OCIRepository.spec.ref.tag`; staging/prod
  cluster dirs not yet created.

## NEXT ACTION
Generate keys (`make keys`), populate placeholders, `flux bootstrap` on a k3s
cluster, then run `certification-e2e/run.sh`. Optionally scaffold
`clusters/staging` + `clusters/prod` (tag repin only).
