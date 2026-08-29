# Session Handoff

## STATE
Welkin platform defined as a single Timoni bundle + gitless signed/encrypted
delivery. Local gates (gate-2/gate-3 docker-compose) already existed with
recorded e2e evidence. This session built the platform source, the delivery
pipeline, the certification gate, and ran a ponytail-audit cleanup.

## ACTIVE OBJECTIVE
Stand up the full platform on a real cluster and convert INFERENCE → VERIFIED
via `certification-e2e/run.sh`. Prereq: key/secret wiring + flux bootstrap.

## CURRENT GATE
`certification-e2e/run.sh` (canonical flow + plane independence + OpenMeter
isolation). NOT yet run — no cluster has reconciled the bundle.

## FACTS
- `timoni bundle lint` + `timoni bundle build` pass (9/9 instances valid).
- No real secret renders inline in the bundle (grep-verified); creds injected
  via `envFrom`/`existingSecret` from SOPS-encrypted Secrets generated at CI.
- Two commits this session: `223877d` (platform+delivery), `2ddc698` (audit
  cleanup: deleted `cloudevents.cue`, `image-automation.yaml`, 2 redundant
  Kyverno policies). Both pushed to `origin/gate-2-gate-3-clean`.
- ponytail-audit is the agreed over-engineering check; ran once, cuts applied.

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
Branch `gate-2-gate-3-clean`, pushed. No PR opened (user controls merge).

## TESTS/CI/E2E
- `build.yaml` CI not yet exercised (needs repo secrets: OPENMETER_API_KEY,
  STRIPE_API_KEY, ARCHIVE_S3_*, COSIGN_PRIVATE_KEY, GITHUB_TOKEN).
- `certification-e2e/run.sh` written but unrun (no cluster).

## ADVERSARIAL RESULT
Not run. Claims of isolation are INFERENCE until the e2e gate executes on a
live cluster. Known risk: chart value fields (envFrom, existingSecret, Strimzi
ACL wiring) are schema-valid but runtime-unproven.

## REGRESSIONS CHECKED
- `timoni bundle lint` re-run after audit cleanup → still valid.
- No dangling references to deleted `cloudevents.cue` (grep clean).

## OPEN QUESTIONS
- Real artifact registry/owner: `oci://ghcr.io/OWNER/welkin-manifests` is a
  placeholder in `clusters/dev/ocirepo.yaml` + `build.yaml` — needs the real
  `OWNER`.
- `clusters/dev/secrets.yaml` + `.sops.yaml` carry `REPLACE_WITH_*` placeholders
  for cosign pub / age key — must be filled before any build/sign.
- Promotion model: dev→prod = repin `OCIRepository.spec.ref.tag`; staging/prod
  cluster dirs not yet created.

## NEXT ACTION
Generate keys (`make keys`), populate placeholders, `flux bootstrap` on a k3s
cluster, then run `certification-e2e/run.sh`. Optionally scaffold
`clusters/staging` + `clusters/prod` (tag repin only).
