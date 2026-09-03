#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY="$ROOT/platform/infra/cilium/default-deny.ciliumclusterwidenetworkpolicy.yaml"
POLICY="$ROOT/platform/infra/cilium/workload-policies.yaml"
STRIMZI="$ROOT/platform/infra/strimzi/kafka.yaml"
USERS="$ROOT/platform/infra/strimzi/kafka-users.yaml"
BUNDLE="$ROOT/platform/welkin.bundle.cue"
WORKFLOW="$ROOT/.github/workflows/t5-archive-outage.yaml"

fail(){ echo "FAIL: $*" >&2; exit 1; }
has(){ grep -Fq -- "$1" "$2" || fail "missing '$1' in ${2#$ROOT/}"; }

# T5-16: the workload default-deny must not select Kyverno. Kyverno's
# admission webhook path remains owned by its upstream controller/chart.
has 'values:' "$DENY"
has 'welkin-system' "$DENY"
has 'openmeter-system' "$DENY"
if grep -A12 'values:' "$DENY" | grep -Fq 'kyverno'; then
  fail "Kyverno namespace entered workload default-deny scope"
fi
has 'namespace: "kyverno"' "$BUNDLE"

# T5-17: Strimzi owns its native listener/control-plane NetworkPolicies; the
# Welkin-specific Cilium layer restricts the two actual application clients.
has 'type: internal' "$STRIMZI"
has 'tls: true' "$STRIMZI"
has 'strimzi.io/cluster: welkin-kafka' "$POLICY"
has 'app.kubernetes.io/name: openmeter-collector' "$POLICY"
has 'app.kubernetes.io/name: welkin-archive' "$POLICY"
has 'port: "9093"' "$POLICY"

# T5-18: Timoni dependency ordering plus application data-plane edges.
has 'dependsOn: [{name: "cilium"}]' "$BUNDLE"
has 'dependsOn: [{name: "postgres"}]' "$BUNDLE"
has 'dependsOn: [{name: "openmeter"}, {name: "strimzi"}]' "$BUNDLE"
has 'dependsOn: [{name: "strimzi"}, {name: "minio"}]' "$BUNDLE"
has 'port: "8080"' "$POLICY"
has 'port: "5432"' "$POLICY"
has 'port: "9000"' "$POLICY"

# T5-19: readiness is an explicit runtime gate, not an inferred consequence
# of Kafka being Ready.
has 'kafkauser/welkin-collector-kafka' "$WORKFLOW"
has 'kafkauser/welkin-archive-kafka' "$WORKFLOW"
has 'kafkatopic/welkin_canonical' "$WORKFLOW"

# T5-20: the Kafka probe must structurally compare the top-level CloudEvent id.
# Keep this guard against accidental regression to substring matching.
has 'message.get("id") == event_id' "$ROOT/certification-e2e/run.sh"
if grep -Fq 'grep -qF \"\"id\":\"$id\"\"' "$ROOT/certification-e2e/run.sh"; then
  fail "Kafka identity probe regressed to substring matching"
fi

echo "PASS: T5 static network/dependency audit"
