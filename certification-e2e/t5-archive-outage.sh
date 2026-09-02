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
restore(){ kubectl scale deployment/minio -n "$NS_WELKIN" --replicas="$MINIO_REPLICAS" >/dev/null 2>&1 || true; }
trap restore EXIT
[[ "$MINIO_REPLICAS" =~ ^[1-9][0-9]*$ ]] || { unverified "MinIO replica count is not positive"; exit 2; }
minio_up || { unverified "Object Storage is not healthy"; exit 2; }
kafka_archive_group_lag >/dev/null || { unverified "T4 consumer-group probe unavailable"; exit 2; }
pass "T5 preconditions satisfied"
EVENT_ID="t5-$(uuidgen)"
BODY=$(printf '{"specversion":"1.0","id":"%s","source":"t5","type":"test.t5","time":"2026-01-01T00:00:00Z","subject":"t5","data":{"scenario":"storage-outage"}}' "$EVENT_ID")
curl -fsS -XPOST "http://$COLLECTOR_SVC/api/v1/events" -H 'Content-Type: application/json' -d "$BODY" >/dev/null || { fail "Collector rejected event"; exit 1; }
wait_until 60 kafka_has_event "$EVENT_ID" || { fail "event not retained in Kafka"; exit 1; }
wait_until 60 openmeter_has_event "$EVENT_ID" || { fail "event not in Economic plane"; exit 1; }
pass "baseline event reached Kafka and Economic plane"
kubectl scale deployment/minio -n "$NS_WELKIN" --replicas=0 >/dev/null
wait_until 30 minio_down || { fail "storage outage not established"; exit 1; }
pass "Object Storage unavailable"
EVENT_ID_OUTAGE="t5-$(uuidgen)"
BODY_OUTAGE=$(printf '{"specversion":"1.0","id":"%s","source":"t5","type":"test.t5","time":"2026-01-01T00:00:01Z","subject":"t5-outage","data":{"scenario":"storage-down"}}' "$EVENT_ID_OUTAGE")
curl -fsS -XPOST "http://$COLLECTOR_SVC/api/v1/events" -H 'Content-Type: application/json' -d "$BODY_OUTAGE" >/dev/null || { fail "Collector rejected outage event"; exit 1; }
wait_until 60 kafka_has_event "$EVENT_ID_OUTAGE" || { fail "outage event not retained in Kafka"; exit 1; }
wait_until 30 lag_positive || { fail "Archive lag did not increase"; exit 1; }
wait_until 30 openmeter_has_event "$EVENT_ID_OUTAGE" || { fail "Economic plane failed during storage outage"; exit 1; }
pass "Kafka retained event, Archive lagged, Economic plane stayed functional"
restore
wait_until 90 minio_up || { fail "Object Storage did not recover"; exit 1; }
wait_until 120 archive_has_event "$EVENT_ID_OUTAGE" || { fail "event not persisted after recovery"; exit 1; }
wait_until 120 caught_up || { fail "Archive did not catch up"; exit 1; }
pass "Archive recovered, persisted event, and caught up"
mkdir -p "${T5_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/welkin-t5}"
printf '{"task":"T5","scenario":"object-storage-outage-recovery","event_id":"%s","result":"PASS"}\n' "$EVENT_ID_OUTAGE" > "${T5_ARTIFACT_DIR:-${RUNNER_TEMP:-/tmp}/welkin-t5}/certification.json"
echo "== T5 RESULT: $PASS pass, $FAIL fail, $UNVERIFIED unverified =="
[[ "$FAIL" -eq 0 && "$UNVERIFIED" -eq 0 ]]
