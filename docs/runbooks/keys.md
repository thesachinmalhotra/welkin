# Key Generation & Wiring

Two mechanisms protect the artifact: **age** (SOPS secret encryption) and
**keyless cosign** (artifact signature verification via GHA OIDC).

## 1. Generate age keypair (SOPS)

```bash
age-keygen -o keys/age.key        # prints PUBLIC key (age1...)
```

Never commit `keys/age.key`. Add `keys/` to `.gitignore`.

Cosign is keyless — no `cosign generate-key-pair`, no `cosign.key`/`cosign.pub`,
no `cosign-public-key` Secret. CI signs with ambient GHA OIDC
(`permissions: id-token: write`); Flux verifies via
`clusters/*/ocirepo.yaml: spec.verify.matchOIDCIdentity`.

## 2. Wire age (SOPS)

Edit `.sops.yaml` — replace `REPLACE_WITH_AGE_PUBLIC_KEY` with the age public
key. Re-encrypt secrets:

```bash
SOPS_AGE_KEY_FILE=keys/age.key sops updatekeys <secret-file>
```

Base64 the private key into every `clusters/*/secrets.yaml`:

```bash
kubectl create secret generic sops-age -n flux-system \
  --from-file=age.agekey=keys/age.key --dry-run=client -o jsonpath='{.data.age\.agekey}'
```

Paste that value over `REPLACE_WITH_BASE64_AGE_PRIVATE_KEY`.

## 3. Wire cosign (Flux verify) — keyless

No key to wire. Confirm `clusters/*/ocirepo.yaml` contains:

```yaml
verify:
  provider: cosign
  matchOIDCIdentity:
    - issuer: "^https://token.actions.githubusercontent.com$"
      subject: "^https://github.com/<OWNER>/<REPO>/.github/workflows/build.yaml@refs/heads/main$"
    - issuer: "^https://token.actions.githubusercontent.com$"
      subject: "^https://github.com/<OWNER>/<REPO>/.github/workflows/build.yaml@refs/tags/v.*$"
```

`subject` must match the workflow that runs `flux push artifact` + `cosign sign`
(`build.yaml`, not any ephemeral cert workflow). Flux source-controller verifies
the Fulcio cert + Rekor inclusion; `kubectl describe ocirepository welkin` shows
`SourceVerified: True` or `VerificationError: no matching signatures`.

## 4. CI secrets

Set in the `build.yaml` repo / environment:

- `OPENMETER_API_KEY`, `STRIPE_API_KEY`, `ARCHIVE_S3_ACCESS_KEY_ID`,
  `ARCHIVE_S3_SECRET_ACCESS_KEY` — injected as SOPS-encrypted Secrets;
  `build.yaml` has no `COSIGN_PRIVATE_KEY`.

The private `age.key` is also needed by Flux on the cluster — ship it via a
sealed secret / external secrets manager into `flux-system` as `sops-age`.
