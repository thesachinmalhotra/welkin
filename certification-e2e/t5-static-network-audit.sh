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

T5_ARCHIVE="$ROOT/certification-e2e/t5-archive-outage.sh"
# T5-21: archive lookup must enumerate every object page and inspect only the
# canonical Parquet identity column; a single ListObjectsV2 page is insufficient.
has 'get_paginator("list_objects_v2")' "$T5_ARCHIVE"
has 'columns=["id"]' "$T5_ARCHIVE"

# T5-22: the causal proof must remain explicitly scoped to the tested storage
# boundary rather than silently claiming a direct negative object-store query.
has 'not queried in storage during the outage' "$ROOT/docs/t5-evidence-contract.md"
has 'untested alternate write path' "$ROOT/docs/t5-evidence-contract.md"

# T5-23: collector readiness must exercise the real POST-only endpoint without
# generating an event; 405 is the expected response to a GET.
has '[[ "$http_code" == "405" ]]' "$T5_ARCHIVE"
has '--address 127.0.0.1' "$T5_ARCHIVE"

# T5-24: outage confirmation requires both zero desired replicas and no
# EndpointSlice addresses before the outage event is accepted.
has '[[ "$desired" == "0" ]]' "$T5_ARCHIVE"
has '[[ -z "$endpoints" ]]' "$T5_ARCHIVE"
has 'wait_until 30 minio_down' "$T5_ARCHIVE"

# T5-25: recovery must release the temporary Flux suspension and prove the
# HelmRelease + MinIO endpoint state is healthy again.
has 'patch helmrelease/minio' "$T5_ARCHIVE"
has 'wait --for=condition=Ready helmrelease/minio' "$T5_ARCHIVE"
has 'wait_until 30 minio_up' "$T5_ARCHIVE"
has 'trap cleanup EXIT' "$T5_ARCHIVE"

echo "PASS: T5 static network/dependency audit"
