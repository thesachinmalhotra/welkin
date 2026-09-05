# Welkin platform — local + CI tasks.
# Prereqs (dev): timoni, yq, kubectl, cosign, sops, age, k3d/k3s (for e2e).

.PHONY: lint build export-gates e2e t5-preflight keys

# Lint the Timoni bundle (CUE package compiles + instances valid).
lint:
	timoni bundle lint -f platform/welkin.bundle.cue

# Render the bundle to plain manifests (verifies the whole platform compiles).
build:
	timoni bundle build -f platform/welkin.bundle.cue > /tmp/welkin-manifests.yaml

# Derive the local gates/ collector config from the SAME rendered values, so
# the docker-compose smoke can't drift from prod. Requires yq.
export-gates: build
	yq 'select(.metadata.name=="collector") | .spec.values.config' \
		/tmp/welkin-manifests.yaml > gates/gate-2/collector/config.yaml
	@echo "wrote gates/gate-2/collector/config.yaml from rendered bundle"

# Certification gate on a k3s cluster (canonical flow + plane independence +
# isolation assertions). See certification-e2e/run.sh.
e2e:
	./certification-e2e/run.sh

# Full T5 preflight: validates the exact CI execution surface without starting CI.
t5-preflight:
	./certification-e2e/t5-preflight.sh

# Generate age + cosign keypairs for SOPS/Flux verification (one-time).
keys:
	@echo "age:"; age-keygen -o /tmp/age.key 2>/tmp/age.pub; cat /tmp/age.pub
	@echo "cosign:"; cosign generate-key-pair
	@echo "-> store private halves in CI secrets; public halves in clusters/*/secrets.yaml + .sops.yaml"
