#!/usr/bin/env bash
set -euo pipefail

# T5 certifies exactly one failure boundary:
# Object Storage disappears after a baseline event, while canonical events
# remain durable in Kafka and Economic remains functional; after storage
# recovery the exact outage event is archived and the Archive consumer catches up.

wait_until(){ # timeout_s cmd...
  local timeout_s=$1
  shift
  local deadline=$((SECONDS + timeout_s))
  until "$@"; do
    if (( SECONDS >= deadline )); then
      return 1
    fi
    sleep 2
  done
}

NS_WELKIN=welkin-system
NS_ECON=openmeter-system
TOPIC=welkin_canonical
BUCKET=welkin-archive
FDQN_KAFKA="welkin-kafka-kafka-bootstrap.${NS_WELKIN}.svc:9093"
COLLECTOR_LOCAL_URL="http://127.0.0.1:18080"
STRIMZI_KAFKA_IMAGE="quay.io/strimzi/kafka:0.45.0-kafka-3.9.0"

# Reuse the audited Kafka/OpenMeter/group probe implementations.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/t5-kafka-probes.sh"

PASS=0
FAIL=0
UNVERIFIED=0
COLLECTOR_PORT_PID=0
T5_ARTIFACT_DIR="${T5_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/welkin-t5}"
mkdir -p "$T5_ARTIFACT_DIR"
RUN_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)

pass(){ echo "PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }
unverified(){ echo "UNVERIFIED: $1"; UNVERIFIED=$((UNVERIFIED+1)); }


start_collector_port_forward(){
  kubectl port-forward --address 127.0.0.1 -n "$NS_WELKIN" svc/openmeter-collector 18080:8080 \
    >"${T5_ARTIFACT_DIR}/collector-port-forward.log" 2>&1 &
  COLLECTOR_PORT_PID=$!
  for _ in {1..30}; do
    if ! kill -0 "$COLLECTOR_PORT_PID" 2>/dev/null; then
      echo "collector port-forward exited" >&2
      return 1
    fi
    # The collector's ingestion endpoint accepts POST only. A GET therefore
    # returning 405 is the expected application-level response and proves the
    # port-forward reached the actual HTTP server rather than merely spawning.
    http_code=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' \
      "$COLLECTOR_LOCAL_URL/api/v1/events" 2>/dev/null || true)
    if [[ "$http_code" == "405" ]]; then
      return 0
    fi
    sleep 1
  done
  echo "collector port-forward never became reachable" >&2
  return 1
}

stop_collector_port_forward(){
  if [[ "$COLLECTOR_PORT_PID" -ne 0 ]]; then
    kill "$COLLECTOR_PORT_PID" 2>/dev/null || true
    wait "$COLLECTOR_PORT_PID" 2>/dev/null || true
    COLLECTOR_PORT_PID=0
  fi
}

minio_up(){
  local desired ready endpoints
  desired=$(kubectl get deployment/minio -n "$NS_WELKIN" -o jsonpath='{.spec.replicas}') || return 2
  ready=$(kubectl get deployment/minio -n "$NS_WELKIN" -o jsonpath='{.status.readyReplicas}') || return 2
  endpoints=$(kubectl get endpointslice -n "$NS_WELKIN" -l kubernetes.io/service-name=minio -o jsonpath='{.items[*].endpoints[*].addresses[*]}') || return 2
  [[ "$desired" =~ ^[1-9][0-9]*$ ]] && [[ "$ready" == "$desired" ]] && [[ -n "$endpoints" ]]
}

minio_down(){
  local desired endpoints
  desired=$(kubectl get deployment/minio -n "$NS_WELKIN" -o jsonpath='{.spec.replicas}') || return 2
  endpoints=$(kubectl get endpointslice -n "$NS_WELKIN" -l kubernetes.io/service-name=minio -o jsonpath='{.items[*].endpoints[*].addresses[*]}') || return 2
  [[ "$desired" == "0" ]] && [[ -z "$endpoints" ]]
}

lag_positive(){
  local x
  x=$(kafka_archive_group_lag) && [[ "$x" -gt 0 ]]
}

caught_up(){
  local x
  x=$(kafka_archive_group_lag) && [[ "$x" -eq 0 ]]
}

MINIO_REPLICAS=$(kubectl get deployment/minio -n "$NS_WELKIN" -o jsonpath='{.spec.replicas}')
[[ "$MINIO_REPLICAS" =~ ^[1-9][0-9]*$ ]] || {
  unverified "MinIO replica count is not positive"
  exit 2
}
MINIO_OUTAGE_ACTIVE=0
MINIO_HR_SUSPENDED=0

restore_minio(){
  local result=0
  if [[ "$MINIO_OUTAGE_ACTIVE" -eq 1 ]]; then
    kubectl scale deployment/minio -n "$NS_WELKIN" \
      --current-replicas=0 --replicas="$MINIO_REPLICAS" >/dev/null || result=1
    if [[ "$result" -eq 0 ]] && ! wait_until 90 minio_up; then
      result=1
    fi
  fi
  # Always release the test-only HelmRelease suspension, even if scaling or
  # health recovery failed, so cleanup cannot strand the desired state paused.
  if [[ "$MINIO_HR_SUSPENDED" -eq 1 ]]; then
    kubectl patch helmrelease/minio -n "$NS_WELKIN" --type=merge -p '{"spec":{"suspend":false}}' >/dev/null || result=1
    if [[ "$result" -eq 0 ]] && ! kubectl wait --for=condition=Ready helmrelease/minio -n "$NS_WELKIN" --timeout=120s; then
      result=1
    fi
    if [[ "$result" -eq 0 ]] && ! wait_until 30 minio_up; then
      result=1
    fi
    MINIO_HR_SUSPENDED=0
  fi
  if [[ "$result" -eq 0 ]]; then
    MINIO_OUTAGE_ACTIVE=0
  fi
  return "$result"
}

cleanup(){
  local status=$?
  trap - EXIT
  if ! restore_minio; then
    echo "FAIL: Object Storage cleanup did not complete" >&2
    [[ "$status" -eq 0 ]] && status=1
  fi
  stop_collector_port_forward
  exit "$status"
}
trap cleanup EXIT

minio_up || { unverified "Object Storage is not healthy"; exit 2; }
start_collector_port_forward || { unverified "Collector port-forward unavailable"; exit 2; }
kafka_archive_group_lag >/dev/null || {
  unverified "T4 consumer-group probe unavailable"
  exit 2
}
pass "T5 preconditions satisfied"

BASELINE_EVENT_ID="t5-$(python3 -c 'import uuid; print(uuid.uuid4())')"
BASELINE_POSTED_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
BASELINE_BODY=$(printf '{"specversion":"1.0","id":"%s","source":"t5","type":"test.t5","time":"%s","subject":"t5","data":{"scenario":"storage-outage"}}' \
  "$BASELINE_EVENT_ID" "$BASELINE_POSTED_AT")

curl -fsS -XPOST "$COLLECTOR_LOCAL_URL/api/v1/events" \
  -H 'Content-Type: application/json' -d "$BASELINE_BODY" >/dev/null || {
  fail "Collector rejected baseline event"
  exit 1
}
wait_until 60 kafka_has_event "$BASELINE_EVENT_ID" || {
  fail "baseline event not retained in Kafka"
  exit 1
}
wait_until 60 openmeter_has_event "$BASELINE_EVENT_ID" || {
  fail "baseline event not in Economic plane"
  exit 1
}
BASELINE_LAG=$(kafka_archive_group_lag) || {
  fail "Unable to capture baseline Archive lag"
  exit 1
}
[[ "$BASELINE_LAG" == "0" ]] || {
  fail "Archive was not caught up before outage (lag=$BASELINE_LAG)"
  exit 1
}
pass "baseline event reached Kafka and Economic plane with Archive caught up"

STORAGE_OUTAGE_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
kubectl patch helmrelease/minio -n "$NS_WELKIN" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
MINIO_HR_SUSPENDED=1
kubectl scale deployment/minio -n "$NS_WELKIN" \
  --current-replicas="$MINIO_REPLICAS" --replicas=0 >/dev/null
MINIO_OUTAGE_ACTIVE=1
wait_until 30 minio_down || {
  fail "storage outage not established"
  exit 1
}

OUTAGE_STORAGE_CONFIRMED_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
OUTAGE_MINIO_REPLICAS=$(kubectl get deployment/minio -n "$NS_WELKIN" -o jsonpath='{.spec.replicas}')
[[ "$OUTAGE_MINIO_REPLICAS" == "0" ]] || {
  fail "MinIO Deployment replica count was not zero at outage confirmation"
  exit 1
}
pass "Object Storage unavailable with Deployment replicas=0"

EVENT_ID_OUTAGE="t5-$(python3 -c 'import uuid; print(uuid.uuid4())')"
OUTAGE_EVENT_POST_ATTEMPTED_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)
OUTAGE_BODY=$(printf '{"specversion":"1.0","id":"%s","source":"t5","type":"test.t5","time":"%s","subject":"t5-outage","data":{"scenario":"storage-down"}}' \
  "$EVENT_ID_OUTAGE" "$OUTAGE_EVENT_POST_ATTEMPTED_AT")

curl -fsS -XPOST "$COLLECTOR_LOCAL_URL/api/v1/events" \
  -H 'Content-Type: application/json' -d "$OUTAGE_BODY" >/dev/null || {
  fail "Collector rejected outage event"
  exit 1
}
OUTAGE_EVENT_ACCEPTED_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)

wait_until 60 kafka_has_event "$EVENT_ID_OUTAGE" || {
  fail "outage event not retained in Kafka"
  exit 1
}
wait_until 30 lag_positive || {
  fail "Archive lag did not become positive"
  exit 1
}
LAG_DURING=$(kafka_archive_group_lag) || {
  fail "Unable to capture Archive lag during outage"
  exit 1
}
[[ "$LAG_DURING" =~ ^[1-9][0-9]*$ ]] || {
  fail "Archive lag was not positive at capture"
  exit 1
}
wait_until 60 openmeter_has_event "$EVENT_ID_OUTAGE" || {
  fail "Economic plane failed during storage outage"
  exit 1
}
pass "Kafka retained event, Archive lagged, Economic plane stayed functional"

restore_minio || { fail "Object Storage did not recover"; exit 1; }
STORAGE_RECOVERED_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)

wait_until 180 archive_has_event "$EVENT_ID_OUTAGE" || {
  fail "exact outage event not persisted after recovery"
  exit 1
}
ARCHIVED_AT=$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)

wait_until 120 caught_up || {
  fail "Archive did not catch up"
  exit 1
}
LAG_AFTER=$(kafka_archive_group_lag) || {
  fail "Unable to capture final Archive lag"
  exit 1
}
[[ "$LAG_AFTER" == "0" ]] || {
  fail "Archive lag was not zero after recovery"
  exit 1
}

TEMPORAL_STORAGE_BEFORE_ACCEPTANCE=false
TEMPORAL_RECOVERY_BEFORE_ARCHIVE=false
[[ "$OUTAGE_STORAGE_CONFIRMED_AT" < "$OUTAGE_EVENT_ACCEPTED_AT" ]] && TEMPORAL_STORAGE_BEFORE_ACCEPTANCE=true
[[ "$STORAGE_RECOVERED_AT" < "$ARCHIVED_AT" ]] && TEMPORAL_RECOVERY_BEFORE_ARCHIVE=true

OUTAGE_EVENT_NOT_PERSISTED_DURING_OUTAGE=false
if [[ "$TEMPORAL_STORAGE_BEFORE_ACCEPTANCE" == true && "$TEMPORAL_RECOVERY_BEFORE_ARCHIVE" == true ]]; then
  OUTAGE_EVENT_NOT_PERSISTED_DURING_OUTAGE=true
fi

END_TO_END_CORRELATED=true
ARCHIVE_LAG_POSITIVE=true
ARCHIVE_LAG_ZERO=true

export RUN_STARTED_AT BASELINE_EVENT_ID BASELINE_POSTED_AT \
  STORAGE_OUTAGE_STARTED_AT OUTAGE_STORAGE_CONFIRMED_AT \
  OUTAGE_EVENT_POST_ATTEMPTED_AT OUTAGE_EVENT_ACCEPTED_AT \
  STORAGE_RECOVERED_AT ARCHIVED_AT EVENT_ID_OUTAGE \
  LAG_DURING LAG_AFTER BASELINE_LAG MINIO_REPLICAS OUTAGE_MINIO_REPLICAS \
  TEMPORAL_STORAGE_BEFORE_ACCEPTANCE TEMPORAL_RECOVERY_BEFORE_ARCHIVE \
  OUTAGE_EVENT_NOT_PERSISTED_DURING_OUTAGE END_TO_END_CORRELATED \
  ARCHIVE_LAG_POSITIVE ARCHIVE_LAG_ZERO

pass "Archive recovered, exact event persisted, and consumer caught up"

python3 - "$T5_ARTIFACT_DIR/certification.json" <<'PY'
import json
import os
import subprocess
import sys

path = sys.argv[1]
def sh(*args):
    return subprocess.check_output(args, text=True).strip()

record = {
    "artifact_version": 2,
    "task": "T5",
    "scenario": "object-storage-outage-recovery",
    "failure_injection": {
        "method": "kubernetes-deployment-scale-to-zero",
        "minio_replicas_before": int(os.environ["MINIO_REPLICAS"]),
        "minio_replicas_at_outage_confirmation": int(os.environ["OUTAGE_MINIO_REPLICAS"]),
    },
    "run_started_at": os.environ["RUN_STARTED_AT"],
    "cluster_context": sh("kubectl", "config", "current-context"),
    "namespace": "welkin-system",
    "baseline_event_id": os.environ["BASELINE_EVENT_ID"],
    "outage_event_id": os.environ["EVENT_ID_OUTAGE"],
    "baseline_posted_at": os.environ["BASELINE_POSTED_AT"],
    "baseline_archive_lag": int(os.environ["BASELINE_LAG"]),
    "archive_lag_during_outage": int(os.environ["LAG_DURING"]),
    "archive_lag_after_recovery": int(os.environ["LAG_AFTER"]),
    "storage_outage_started_at": os.environ["STORAGE_OUTAGE_STARTED_AT"],
    "storage_unavailable_confirmed_at": os.environ["OUTAGE_STORAGE_CONFIRMED_AT"],
    "outage_event_post_attempted_at": os.environ["OUTAGE_EVENT_POST_ATTEMPTED_AT"],
    "outage_event_accepted_at": os.environ["OUTAGE_EVENT_ACCEPTED_AT"],
    "storage_recovered_at": os.environ["STORAGE_RECOVERED_AT"],
    "archived_at": os.environ["ARCHIVED_AT"],
    "temporal_order": {
        "storage_confirmed_before_event_acceptance": os.environ["TEMPORAL_STORAGE_BEFORE_ACCEPTANCE"] == "true",
        "storage_recovered_before_archive_observation": os.environ["TEMPORAL_RECOVERY_BEFORE_ARCHIVE"] == "true",
    },
    "evidence": {
        "baseline_event_in_kafka": True,
        "baseline_event_in_openmeter": True,
        "storage_unavailable_confirmed": True,
        "outage_event_in_kafka": True,
        "outage_event_in_openmeter": True,
        "outage_event_not_persisted_during_outage": os.environ["OUTAGE_EVENT_NOT_PERSISTED_DURING_OUTAGE"] == "true",
        "archive_lag_positive_during_outage": os.environ["ARCHIVE_LAG_POSITIVE"] == "true",
        "outage_event_in_parquet_after_recovery": True,
        "outage_event_id_correlated_end_to_end": os.environ["END_TO_END_CORRELATED"] == "true",
        "canonical_identity_field": "id",
        "archive_lag_zero_after_recovery": os.environ["ARCHIVE_LAG_ZERO"] == "true",
    },
}
with open(path, "w") as f:
    json.dump(record, f, indent=2, sort_keys=True)
    f.write("\n")
PY

echo "== T5 RESULT: $PASS pass, $FAIL fail, $UNVERIFIED unverified =="
[[ "$FAIL" -eq 0 && "$UNVERIFIED" -eq 0 ]]
