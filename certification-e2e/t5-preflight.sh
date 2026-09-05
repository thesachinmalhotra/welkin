#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail(){ echo "FAIL: $*" >&2; exit 1; }
require_cmd(){ command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }
has(){ grep -Fq -- "$1" "$2" || fail "missing '$1' in ${2#$ROOT/}"; }
not_has(){ grep -Fq -- "$1" "$2" && fail "forbidden '$1' found in ${2#$ROOT/}" || true; }

echo "== T5 preflight: repository and execution surface =="

require_cmd bash
require_cmd git
require_cmd timoni
require_cmd kubectl
require_cmd helm
require_cmd python3
not_has 'archive_has_event(){' certification-e2e/t5-archive-outage.sh
require_cmd jq
require_cmd curl
require_cmd actionlint

git diff --check

for f in certification-e2e/t5-archive-outage.sh certification-e2e/t5-kafka-probes.sh certification-e2e/t5-static-network-audit.sh; do
  bash -n "$f" || fail "shell syntax failed: $f"
done
actionlint .github/workflows/t5-archive-outage.yaml

WORKFLOW=.github/workflows/t5-archive-outage.yaml
T5=certification-e2e/t5-archive-outage.sh
PROBES=certification-e2e/t5-kafka-probes.sh

has "workflow_dispatch:" "$WORKFLOW"
not_has "enableEnvoyConfig" "$WORKFLOW"
not_has "uuidgen" "$T5"
has "date -u +%Y-%m-%dT%H:%M:%S.%NZ" "$T5"
has "--set envoyConfig.enabled=true" "$WORKFLOW"
has 'source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/t5-kafka-probes.sh"' "$T5"
not_has 'source "./t5-kafka-probes.sh"' "$T5"
has "requirements-t5.txt" "$WORKFLOW"
has "actions/setup-python@v6.2.0" "$WORKFLOW"
has "python-version: '3.12.3'" "$WORKFLOW"
has "python -m venv /tmp/t5-venv" "$WORKFLOW"
has "-r certification-e2e/requirements-t5.txt" "$WORKFLOW"
has 'get_paginator("list_objects_v2")' "$PROBES"
has 'columns=["id"]' "$PROBES"
not_has '--image="${ARCHIVE_PROBE_IMAGE:-python:3.12-slim}"' "$PROBES"
has 'message.get("id") == event_id' "$PROBES"

python3 - <<'PY'
from pathlib import Path
import re

req = Path("certification-e2e/requirements-t5.txt").read_text().splitlines()
expected = {"boto3==1.43.88", "pyarrow==25.0.1"}
if set(req) != expected:
    raise SystemExit(f"FAIL: T5 probe dependency pins are not exactly {sorted(expected)}: {req!r}")

workflow = Path(".github/workflows/t5-archive-outage.yaml").read_text()
for path in re.findall(r'(?:(?:platform|certification-e2e|\.github)/[A-Za-z0-9_./-]+)', workflow):
    if path.endswith((".yaml", ".cue", ".sh", ".txt")) and not Path(path).exists():
        raise SystemExit(f"FAIL: workflow references missing repository file: {path}")
print("PASS: workflow file references resolve")
PY

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== Timoni bundle compile =="
timoni bundle lint -f platform/welkin.bundle.cue
timoni bundle build -f platform/welkin.bundle.cue --runtime-from-env > "$TMP/welkin-manifests.yaml"

count="$(grep -c '^# Instance:' "$TMP/welkin-manifests.yaml")"
[[ "$count" == "7" ]] || fail "expected 7 Timoni instances, got $count"
for instance in kyverno strimzi postgres openmeter collector archive minio; do
  grep -q "^# Instance: $instance$" "$TMP/welkin-manifests.yaml" || fail "missing rendered instance: $instance"
done
not_has 'cilium:' platform/welkin.bundle.cue
not_has 'dependsOn: [{name: "cilium"}]' platform/welkin.bundle.cue

echo "== Exact T5 artifact assembly =="
mkdir -p "$TMP/artifact/foundation" "$TMP/artifact/infra/cilium" "$TMP/artifact/infra/kyverno" "$TMP/artifact/infra/strimzi" "$TMP/artifact/apps"
cp platform/infra/namespaces.yaml "$TMP/artifact/foundation/namespaces.yaml"

awk -v root="$TMP/artifact" '
/^# Instance: / {
  instance=$3
  if (instance ~ /^(kyverno|strimzi|postgres|minio)$/) out=root "/foundation/welkin.yaml"
  else if (instance ~ /^(openmeter|collector|archive)$/) out=root "/apps/welkin.yaml"
  else { print "unexpected instance " instance > "/dev/stderr"; exit 1 }
  next
}
/^---$/ { next }
/^apiVersion:/ { print "---" > out; print > out; next }
out != "" { print > out; next }
NF { print "unexpected rendered line for instance " instance > "/dev/stderr"; exit 1 }
' "$TMP/welkin-manifests.yaml"

cp platform/infra/cilium/*.yaml "$TMP/artifact/infra/cilium/"
cp platform/infra/kyverno/*.yaml "$TMP/artifact/infra/kyverno/"
cp platform/infra/strimzi/*.yaml "$TMP/artifact/infra/strimzi/"

foundation_hrs="$(grep -c '^kind: HelmRelease$' "$TMP/artifact/foundation/welkin.yaml")"
apps_hrs="$(grep -c '^kind: HelmRelease$' "$TMP/artifact/apps/welkin.yaml")"
[[ "$foundation_hrs" == "4" ]] || fail "T5 foundation expected 4 HelmReleases, got $foundation_hrs"
[[ "$apps_hrs" == "3" ]] || fail "T5 apps expected 3 HelmReleases, got $apps_hrs"

cat > "$TMP/artifact/foundation/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- namespaces.yaml
- welkin.yaml
EOF
cat > "$TMP/artifact/infra/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- cilium/base-allow.ciliumclusterwidenetworkpolicy.yaml
- cilium/default-deny.ciliumclusterwidenetworkpolicy.yaml
- cilium/workload-policies.yaml
- kyverno/policies.yaml
- strimzi/kafka.yaml
- strimzi/kafka-users.yaml
EOF
cat > "$TMP/artifact/apps/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- welkin.yaml
EOF

kubectl kustomize "$TMP/artifact/foundation" > "$TMP/foundation.yaml"
kubectl kustomize "$TMP/artifact/infra" > "$TMP/infra.yaml"
kubectl kustomize "$TMP/artifact/apps" > "$TMP/apps.yaml"

grep -q '^kind: Namespace$' "$TMP/foundation.yaml" || fail "foundation artifact does not contain Namespace resources"
for ns in kyverno welkin-system openmeter-system; do
  grep -A2 -q "^  name: $ns$" "$TMP/foundation.yaml" || fail "foundation artifact missing namespace $ns"
done

echo "== Static network/dependency audit =="
bash certification-e2e/t5-static-network-audit.sh

echo "== T5 preflight PASS: no repository/bootstrap/probe wiring defect detected =="
