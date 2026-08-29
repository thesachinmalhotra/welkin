# Key Generation & Wiring

Two keypairs protect the artifact: **age** (SOPS secret encryption) and
**cosign** (artifact signature verification). Generate once, keep private
halves in CI secrets, publish public halves in the repo.

## 1. Generate

```bash
# age keypair (SOPS)
age-keygen -o keys/age.key        # prints PUBLIC key (age1...)

# cosign keypair (artifact signing)
cosign generate-key-pair          # writes cosign.key (private) + cosign.pub
```

Never commit `keys/age.key` or `cosign.key`. Add `keys/` to `.gitignore`.

## 2. Wire age (SOPS)

Edit `.sops.yaml` — replace `REPLACE_WITH_AGE_PUBLIC_KEY` with the age public
key. Re-encrypt secrets:

```bash
SOPS_AGE_KEY_FILE=keys/age.key sops updatekeys <secret-file>
```

## 3. Wire cosign (Flux verify)

Base64 the public key and drop it into every `clusters/*/secrets.yaml`:

```bash
kubectl create secret generic cosign-public-key -n flux-system \
  --from-file=cosign.pub=cosign.pub --dry-run=client -o jsonpath='{.data.cosign\.pub}'
```

Paste that value over `REPLACE_WITH_BASE64_COSIGN_PUB`. Same for
`sops-age.age.agekey` (base64 of `keys/age.key`).

## 4. CI secrets

Set in the `build.yaml` repo / environment:

- `SOPS_AGE_KEY` — contents of `keys/age.key`
- `COSIGN_PRIVATE_KEY` — contents of `cosign.key`
- `COSIGN_PASSWORD` — if the key is password-protected (recommended)

The private `age.key` is also needed by Flux on the cluster — ship it via a
sealed secret / external secrets manager into `flux-system` as `sops-age`.
