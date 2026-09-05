kafka_has_event(){ # event_id
  local id=$1
  local out
  out=$(kubectl run "e2e-kafka-probe-$(date +%s%N)" --rm -i --restart=Never --quiet \
    --image="$STRIMZI_KAFKA_IMAGE" --namespace "$NS_WELKIN" \
    --overrides='{
      "apiVersion":"v1",
      "kind":"Pod",
      "metadata":{"labels":{"app.kubernetes.io/name":"welkin-archive"}},
      "spec":{
        "containers":[{
          "name":"probe",
          "image":"'"$STRIMZI_KAFKA_IMAGE"'",
          "command":["/bin/bash","-lc",
            "kafka-console-consumer.sh --bootstrap-server '"$FDQN_KAFKA"' "+
            "--topic '"$TOPIC"' --from-beginning --timeout-ms 10000 --max-messages 500 "+
            "--consumer-property security.protocol=SSL "+
            "--consumer-property ssl.truststore.type=PEM "+
            "--consumer-property ssl.truststore.certificates=/etc/kafka/tls/ca.crt "+
            "--consumer-property ssl.keystore.type=PEM "+
            "--consumer-property ssl.keystore.key=/etc/kafka/tls/user.key "+
            "--consumer-property ssl.keystore.certificate.chain=/etc/kafka/tls/user.crt "+
            "| grep -F \""'"$id"'"\""],
          "volumeMounts":[
            {"name":"tls","mountPath":"/etc/kafka/tls","readOnly":true}
          ]
        }],
        "serviceAccountName":"'"$(kubectl get pod -n "$NS_WELKIN" -l app.kubernetes.io/name=welkin-archive -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null || echo welkin-archive)"'",
        "volumes":[
          {"name":"tls","secret":{"secretName":"'"$([[ -n "${KAFKA_PROBE_SECRET:-}" ]] && echo "$KAFKA_PROBE_SECRET" || echo "welkin-archive-kafka")"'"}}
        ],
        "restartPolicy":"Never"
      }}' 2>/dev/null || true)
  # Parse each Kafka message as JSON and compare the canonical CloudEvent
  # `id` field structurally. Do not use substring matching: a matching string
  # nested in `data`, logs, or another field is not proof of event identity.
  printf '%s\n' "$out" | python3 -c '
import json
import sys

event_id = sys.argv[1]
for line in sys.stdin:
    try:
        message = json.loads(line)
    except json.JSONDecodeError:
        continue
    if isinstance(message, dict) and message.get("id") == event_id:
        raise SystemExit(0)
raise SystemExit(1)
' "$id"
}

# openmeter_has_event event_id — query OpenMeter through its Service from the
# runner. Do not exec into the application container: the image must not be
# assumed to contain curl or jq. The chart Service exposes port 80.
openmeter_has_event(){ # event_id
  local id=$1 pid=0 token ready=0 response result
  token=$(kubectl get secret welkin-openmeter-token -n "$NS_WELKIN" -o jsonpath='{.data.OPENMETER_API_KEY}' | base64 -d) || return 1
  [[ -n "$token" ]] || return 1
  kubectl port-forward --address 127.0.0.1 -n "$NS_ECON" svc/openmeter-api 18888:80 >"${T5_ARTIFACT_DIR}/openmeter-port-forward.log" 2>&1 &
  pid=$!
  for _ in {1..30}; do
    if ! kill -0 "$pid" 2>/dev/null; then return 1; fi
    response=$(curl -sS --max-time 3 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $token" "http://127.0.0.1:18888/api/v1/events" 2>/dev/null || true)
    if [[ "$response" == "200" ]]; then ready=1; break; fi
    sleep 1
  done
  if [[ "$ready" -ne 1 ]]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  curl -fsS --max-time 5 -H "Authorization: Bearer $token" "http://127.0.0.1:18888/api/v1/events" 2>/dev/null |
    jq -e --arg id "$id" 'any(.[]; .event.id==$id)' >/dev/null 2>&1
  result=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return "$result"
}

# archive_has_event event_id — scan every archived Parquet object for the exact
# canonical id column. The probe runs on the CI runner, where the T5 Python
# dependencies are installed explicitly from certification-e2e/requirements-t5.txt.
archive_has_event(){ # event_id
  local id=$1
  local pid=0 ready=0 result=1

  kubectl port-forward --address 127.0.0.1 -n "$NS_WELKIN" svc/minio 19000:9000 \
    >"${T5_ARTIFACT_DIR}/s3-port-forward.log" 2>&1 &
  pid=$!
  for _ in {1..30}; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "archive probe: MinIO port-forward exited" >&2
      return 1
    fi
    if curl -fsS --max-time 3 http://127.0.0.1:19000/minio/health/live >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [[ "$ready" -ne 1 ]]; then
    echo "archive probe: MinIO port-forward never became healthy" >&2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi

  local access_key secret_key
  access_key=$(kubectl get secret welkin-archive-s3 -n "$NS_WELKIN" \
    -o jsonpath='{.data.ARCHIVE_ACCESS_KEY_ID}' | base64 -d) || result=1
  secret_key=$(kubectl get secret welkin-archive-s3 -n "$NS_WELKIN" \
    -o jsonpath='{.data.ARCHIVE_SECRET_ACCESS_KEY}' | base64 -d) || result=1
  if [[ "$result" -ne 0 || -z "$access_key" || -z "$secret_key" ]]; then
    echo "archive probe: archive credentials unavailable" >&2
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi

  AWS_ACCESS_KEY_ID="$access_key" \
  AWS_SECRET_ACCESS_KEY="$secret_key" \
  ARCHIVE_S3_ENDPOINT="http://127.0.0.1:19000" \
  ARCHIVE_S3_BUCKET="$BUCKET" \
  python3 - "$id" <<'PY' || result=$?
import io
import os
import sys
import boto3
import pyarrow.parquet as pq

event_id = sys.argv[1]
s3 = boto3.client(
    "s3",
    endpoint_url=os.environ["ARCHIVE_S3_ENDPOINT"],
    region_name="us-east-1",
)

for page in s3.get_paginator("list_objects_v2").paginate(
    Bucket=os.environ["ARCHIVE_S3_BUCKET"], Prefix="events/"
):
    for obj in page.get("Contents", []):
        key = obj["Key"]
        if not key.endswith(".parquet"):
            continue
        body = s3.get_object(Bucket=os.environ["ARCHIVE_S3_BUCKET"], Key=key)["Body"].read()
        try:
            table = pq.read_table(io.BytesIO(body), columns=["id"])
        except Exception:
            continue
        if event_id in set(table.column("id").to_pylist()):
            raise SystemExit(0)
raise SystemExit(1)
PY

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return "$result"
}

# Kafka consumer-group offset probe for the Archive plane.
# Uses the same Strimzi Kafka image + TLS Secret as kafka_has_event.
# GROUP is the Archive consumer; TOPIC is welkin_canonical. The helper returns
# the raw `kafka-consumer-groups.sh --describe` table so callers can parse
# CURRENT-OFFSET / LOG-END-OFFSET / LAG per partition and sum LAG across all
# partitions. No production/Kafka/Collector/Archive config is changed.
GROUP="welkin-archive"

# kafka_archive_group_describe — print raw describe table for GROUP/TOPIC.
# Output: header + one row per partition (GROUP TOPIC PARTITION CURRENT-OFFSET LOG-END-OFFSET LAG ...).
# Returns non-zero if the group has no committed offsets yet (CONSUMER group not yet visible).
kafka_archive_group_describe(){
  local pod="e2e-group-probe-$(date +%s%N)"
  local out

  if ! out=$(kubectl run "$pod" --rm -i --restart=Never --quiet \
    --image="$STRIMZI_KAFKA_IMAGE" --namespace "$NS_WELKIN" \
    --overrides='{
      "apiVersion":"v1",
      "kind":"Pod",
      "metadata":{"labels":{"app.kubernetes.io/name":"welkin-archive"}},
      "spec":{
        "containers":[{
          "name":"probe",
          "image":"'"$STRIMZI_KAFKA_IMAGE"'",
          "command":["/bin/bash","-lc",
            "cat >/tmp/client.properties <<PROPS\nsecurity.protocol=SSL\nssl.truststore.type=PEM\nssl.truststore.certificates=/etc/kafka/tls/ca.crt\nssl.keystore.type=PEM\nssl.keystore.key=/etc/kafka/tls/user.key\nssl.keystore.certificate.chain=/etc/kafka/tls/user.crt\nPROPS\nkafka-consumer-groups.sh --bootstrap-server '"$FDQN_KAFKA"' --describe --group '"$GROUP"' --command-config /tmp/client.properties 2>&1"],
          "volumeMounts":[
            {"name":"tls","mountPath":"/etc/kafka/tls","readOnly":true}
          ]
        }],
        "serviceAccountName":"'"$(kubectl get pod -n "$NS_WELKIN" -l app.kubernetes.io/name=welkin-archive -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null || echo welkin-archive)"'",
        "volumes":[
          {"name":"tls","secret":{"secretName":"'"$([[ -n "${KAFKA_PROBE_SECRET:-}" ]] && echo "$KAFKA_PROBE_SECRET" || echo "welkin-archive-kafka")"'"}}
        ],
        "restartPolicy":"Never"
      }}' 2>/dev/null); then
    echo "kafka consumer-group probe command failed" >&2
    return 1
  fi

  printf '%s\n' "$out"
}

# kafka_archive_group_lag — sum LAG across all partitions of TOPIC for GROUP.
# Prints a single integer (0 == fully caught up). Returns 1 if describe produced no rows.
kafka_archive_group_lag(){
  local out
  if ! out=$(kafka_archive_group_describe); then
    echo "kafka consumer-group lag probe failed" >&2
    return 1
  fi
  # Filter to canonical-topic partition rows and sum numeric LAG values.
  printf '%s\n' "$out" | awk -v topic="$TOPIC" '
    $2==topic && $3 ~ /^[0-9]+$/ && $6 ~ /^-?[0-9]+$/ { sum+=$6; found=1 }
    END { if (!found) exit 1; print sum+0 }'
}
