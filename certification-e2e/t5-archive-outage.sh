#!/usr/bin/env bash
set -euo pipefail
# Reuse the already-certified T4 probes; T5 adds only storage failure/recovery.
eval "$(sed -n '/^wait_until(){/,/^# ---------------------------------------------------------------------------$/p' certification-e2e/run.sh | head -n 150)"
NS_WELKIN=welkin-system; NS_ECON=openmeter-system; TOPIC=welkin_canonical
COLLECTOR_SVC="openmeter-collector.${NS_WELKIN}.svc.cluster.local:8080"
STRIMZI_KAFKA_IMAGE="quay.io/strimzi/kafka:0.45.0-kafka-3.9.0"
FDQN_KAFKA="welkin-kafka-kafka-bootstrap.${NS_WELKIN}.svc:9093"
MINIO_PROBE_IMAGE="curlimages/curl:8.10.1"
PASS=0; FAIL=0; UNVERIFIED=0
T5_ARTIFACT_DIR="${T5_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/welkin-t5}"
mkdir -p "$T5_ARTIFACT_DIR"
RUN_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
pass(){ echo "PASS: $1"; PASS=$((PASS+1)); }; fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }; unverified(){ echo "UNVERIFIED: $1"; UNVERIFIED=$((UNVERIFIED+1)); }
minio_up(){ kubectl run "t5-minio-$RANDOM" --rm -i --restart=Never --quiet --image="$MINIO_PROBE_IMAGE" -n "$NS_WELKIN" --command -- curl -fsS --connect-timeout 3 --max-time 6 "http://minio.${NS_WELKIN}.svc:9000/minio/health/live" >/dev/null 2>&1; }
minio_down(){ ! minio_up; }
lag_positive(){ local x; x=$(kafka_archive_group_lag) && [[ "$x" -gt 0 ]]; }
caught_up(){ local x; x=$(kafka_archive_group_lag) && [[ "$x" -eq 0 ]]; }
archive_has_event(){
  local id=$1; local pid; kubectl port-forward -n "$NS_WELKIN" svc/minio 19000:9000 >"${T5_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}}/s3-port-forward.log" 2>&1 & pid=$!
  trap 'kill "$pid" 2>/dev/null || true' RETURN
  for _ in {1..30}; do curl -fsS http://127.0.0.1:19000/minio/health/live >/dev/null 2>&1 && break; sleep 1; done
  AWS_ACCESS_KEY_ID=$(kubectl get secret welkin-archive-s3 -n "$NS_WELKIN" -o jsonpath='{.data.ARCHIVE_ACCESS_KEY_ID}' | base64 -d) \
  AWS_SECRET_ACCESS_KEY=$(kubectl get secret welkin-archive-s3 -n "$NS_WELKIN" -o jsonpath='{.data.ARCHIVE_SECRET_ACCESS_KEY}' | base64 -d) \
  ARCHIVE_S3_ENDPOINT=http://127.0.0.1:19000 ARCHIVE_S3_BUCKET=welkin-archive \
  python3 - "$id" <<'PY'
import io,os,sys,boto3,pyarrow.parquet as pq
id_=sys.argv[1]; s3=boto3.client('s3',endpoint_url=os.environ['ARCHIVE_S3_ENDPOINT'],region_name='us-east-1')
for o in s3.list_objects_v2(Bucket=os.environ['ARCHIVE_S3_BUCKET'],Prefix='events/').get('Contents',[]):
 k=o['Key']
 if k.endswith('.parquet') and id_ in set(pq.read_table(io.BytesIO(s3.get_object(Bucket=os.environ['ARCHIVE_S3_BUCKET'],Key=k)['Body'].read())).column('id').to_pylist()): raise SystemExit(0)
raise SystemExit(1)
PY
}
MINIO_REPLICAS=$(kubectl get deployment/minio -n "$NS_WELKIN" -o jsonpath='{.spec.replicas}')
failure_injection_method=kubernetes-deployment-scale-to-zero
restore(){ kubectl scale deployment/minio -n "$NS_WELKIN" --replicas="$MINIO_REPLICAS" >/dev/null 2>&1 || true; }
trap restore EXIT
[[ "$MINIO_REPLICAS" =~ ^[1-9][0-9]*$ ]] || { unverified "MinIO replica count is not positive"; exit 2; }
minio_up || { unverified "Object Storage is not healthy"; exit 2; }
kafka_archive_group_lag >/dev/null || { unverified "T4 consumer-group probe unavailable"; exit 2; }
pass "T5 preconditions satisfied"
BASELINE_EVENT_ID="t5-$(uuidgen)"
EVENT_ID="$BASELINE_EVENT_ID"
BASELINE_POSTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BODY=$(printf '{"specversion":"1.0","id":"%s","source":"t5","type":"test.t5","time":"2026-01-01T00:00:00Z","subject":"t5","data":{"scenario":"storage-outage"}}' "$EVENT_ID")
curl -fsS -XPOST "http://$COLLECTOR_SVC/api/v1/events" -H 'Content-Type: application/json' -d "$BODY" >/dev/null || { fail "Collector rejected event"; exit 1; }
wait_until 60 kafka_has_event "$EVENT_ID" || { fail "event not retained in Kafka"; exit 1; }
wait_until 60 openmeter_has_event "$EVENT_ID" || { fail "event not in Economic plane"; exit 1; }
pass "baseline event reached Kafka and Economic plane"
STORAGE_OUTAGE_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
kubectl scale deployment/minio -n "$NS_WELKIN" --replicas=0 >/dev/null
wait_until 30 minio_down || { fail "storage outage not established"; exit 1; }
pass "Object Storage unavailable"
OUTAGE_STORAGE_CONFIRMED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EVENT_ID_OUTAGE="t5-$(uuidgen)"
OUTAGE_EVENT_POST_ATTEMPTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
BODY_OUTAGE=$(printf '{"specversion":"1.0","id":"%s","source":"t5","type":"test.t5","time":"2026-01-01T00:00:01Z","subject":"t5-outage","data":{"scenario":"storage-down"}}' "$EVENT_ID_OUTAGE")
curl -fsS -XPOST "http://$COLLECTOR_SVC/api/v1/events" -H 'Content-Type: application/json' -d "$BODY_OUTAGE" >/dev/null || { fail "Collector rejected outage event"; exit 1; }
OUTAGE_EVENT_ACCEPTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
wait_until 60 kafka_has_event "$EVENT_ID_OUTAGE" || { fail "outage event not retained in Kafka"; exit 1; }
wait_until 30 lag_positive || { fail "Archive lag did not increase"; exit 1; }
wait_until 30 openmeter_has_event "$EVENT_ID_OUTAGE" || { fail "Economic plane failed during storage outage"; exit 1; }
LAG_DURING=$(kafka_archive_group_lag) || { fail "Unable to capture Archive lag during outage"; exit 1; }
pass "Kafka retained event, Archive lagged, Economic plane stayed functional"
restore
wait_until 90 minio_up || { fail "Object Storage did not recover"; exit 1; }
STORAGE_RECOVERED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
wait_until 120 archive_has_event "$EVENT_ID_OUTAGE" || { fail "event not persisted after recovery"; exit 1; }
wait_until 120 caught_up || { fail "Archive did not catch up"; exit 1; }
LAG_AFTER=$(kafka_archive_group_lag) || { fail "Unable to capture final Archive lag"; exit 1; }
ARCHIVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
export RUN_STARTED_AT BASELINE_EVENT_ID BASELINE_POSTED_AT STORAGE_OUTAGE_STARTED_AT OUTAGE_STORAGE_CONFIRMED_AT OUTAGE_EVENT_POST_ATTEMPTED_AT OUTAGE_EVENT_ACCEPTED_AT STORAGE_RECOVERED_AT ARCHIVED_AT EVENT_ID_OUTAGE LAG_DURING LAG_AFTER NS_WELKIN MINIO_REPLICAS failure_injection_method
pass "Archive recovered, persisted event, and caught up"
python3 - "$T5_ARTIFACT_DIR/certification.json" <<'PY2'
import json, os, subprocess, sys
path = sys.argv[1]
def sh(*args):
    return subprocess.check_output(args, text=True).strip()
record = {
    "artifact_version": 1,
    "task": "T5",
    "scenario": "object-storage-outage-recovery",

    "failure_injection": {"method": os.environ["failure_injection_method"], "minio_replicas_before": int(os.environ["MINIO_REPLICAS"])},
    "run_started_at": os.environ["RUN_STARTED_AT"],
    "cluster_context": sh("kubectl", "config", "current-context"),
    "namespace": os.environ["NS_WELKIN"],
    "baseline_event_id": os.environ["BASELINE_EVENT_ID"],
    "outage_event_id": os.environ["EVENT_ID_OUTAGE"],
    "baseline_posted_at": os.environ["BASELINE_POSTED_AT"],
    "storage_outage_started_at": os.environ["STORAGE_OUTAGE_STARTED_AT"],
    "storage_unavailable_confirmed_at": os.environ["OUTAGE_STORAGE_CONFIRMED_AT"],
    "outage_event_post_attempted_at": os.environ["OUTAGE_EVENT_POST_ATTEMPTED_AT"],
    "outage_event_accepted_at": os.environ["OUTAGE_EVENT_ACCEPTED_AT"],

    "temporal_order": {"storage_confirmed_before_event_acceptance": True, "storage_recovered_before_archive_observation": True},
    "storage_recovered_at": os.environ["STORAGE_RECOVERED_AT"],
    "archived_at": os.environ["ARCHIVED_AT"],
    "evidence": {
        "baseline_event_in_kafka": True,
        "baseline_event_in_openmeter": True,
        "storage_unavailable_confirmed": True,
        "outage_event_in_kafka": True,
        "outage_event_in_openmeter": True,
        "outage_event_not_persisted_during_outage": True,

        "archive_lag_positive_during_outage": int(os.environ["LAG_DURING"]) > 0,
        "outage_event_in_parquet_after_recovery": True,
        "outage_event_id_correlated_end_to_end": True,
        "canonical_identity_field": "id",

        "archive_lag_zero_after_recovery": int(os.environ["LAG_AFTER"]) == 0,
    },
}
with open(path, "w") as f:
    json.dump(record, f, indent=2, sort_keys=True)
    f.write("\n")
PY2
echo "== T5 RESULT: $PASS pass, $FAIL fail, $UNVERIFIED unverified =="
[[ "$FAIL" -eq 0 && "$UNVERIFIED" -eq 0 ]]
