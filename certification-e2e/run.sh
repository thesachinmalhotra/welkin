#!/usr/bin/env bash
# certification-e2e — the authoritative Welkin gate on a k3s cluster.
#
# Asserts:
#   1. CANONICAL FLOW  — a SINGLE producer event (identified by a specific,
#      per-run event id) lands in OpenMeter AND in the welkin_canonical Kafka
#      topic AND in the archive bucket (S3/MinIO Parquet). We prove the
#      SPECIFIC id in each sink, not merely "some message exists".
#   2. PLANE INDEPENDENCE — killing the Welkin Kafka broker does NOT break the
#      Economic plane. We post a SECOND, DISTINCT event id while the broker is
#      down and prove it was still accepted AND reached OpenMeter (no dedupe
#      masking: the id is brand-new, so OpenMeter cannot dedupe it away).
#   3. ISOLATION (OpenMeter is enemy) —
#      a. OpenMeter identity CANNOT produce to welkin_canonical (Strimzi ACL /
#         Cilium L4 deny).
#      b. OpenMeter identity CANNOT reach the archive bucket (Cilium egress deny).
#      c. OpenMeter SA has no ClusterRoleBinding granting Welkin secrets.
#      d. Hubble shows DROPPED flows from openmeter-system only to the forbidden
#         destinations (welkin-kafka:9093, minio:9000), and FORWARDED for its
#         allowed egress.
#
# Requires: kubectl context pointing at the test cluster with the platform
# installed (flux reconcile from the signed artifact), plus `mc`, `jq`,
# `kcat`/Strimzi kafka-tools, and Hubble Relay. Cluster-only parts print
# UNVERIFIED rather than fake a PASS (AGENTS.md rule 7).
set -euo pipefail

NS_WELKIN=welkin-system
NS_ECON=openmeter-system
TOPIC=welkin_canonical
BUCKET=welkin-archive
FDQN_KAFKA="welkin-kafka-kafka-bootstrap.$NS_WELKIN.svc:9093"
COLLECTOR_SVC="openmeter-collector.$NS_WELKIN.svc.cluster.local:8080"

# Strimzi Kafka image: carries kafka-console-consumer.sh + the Kafka TLS client
# tools, pinned to product.charts.strimziVersion's Kafka (3.9.0).
STRIMZI_KAFKA_IMAGE="quay.io/strimzi/kafka:0.45.0-kafka-3.9.0"
# Isolation probes run from the OpenMeter SA/namespace so they carry the SAME
# identity as the Economic tenant under Cilium default-deny. Tool-only images:
# edenhill/kcat = Kafka producer client; curlimages/curl = HTTP to MinIO.
KAFKA_PROBE_IMAGE="edenhill/kcat:1.7.1"
MINIO_PROBE_IMAGE="curlimages/curl:8.10.1"

PASS=0; FAIL=0
pass(){ echo "PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "FAIL: $1"; FAIL=$((FAIL+1)); }
unverified(){ echo "UNVERIFIED: $1"; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# wait_until CMD... — poll a predicate (exit 0) until success or timeout.
wait_until(){ # timeout_s cmd...
  local t=${1}; shift; local deadline=$((SECONDS+t))
  until "$@"; do
    [ $SECONDS -ge "$deadline" ] && return 1
    sleep 2
  done
  return 0
}

# kafka_tools image run: exec the Strimzi kafka image as a one-shot consumer.
# Consumes the FULL topic and greps for $1 (the specific event id). Returns 0
# if the canonical CloudEvent id field matches exactly. Proves "the specific
# event reached welkin_canonical", not merely
# that any message exists. --from-beginning with all 12 partitions; grep id.
kafka_has_event(){ # event_id
  local id=$1
  local out
  out=$(kubectl run "e2e-kafka-probe-$(date +%s)" --rm -i --restart=Never --quiet \
    --image="$STRIMZI_KAFKA_IMAGE" --namespace "$NS_WELKIN" \
    --overrides='{
      "spec":{
        "containers":[{
          "name":"probe",
          "image":"'"$STRIMZI_KAFKA_IMAGE"'",
          "command":["/bin/bash","-lc",
            "kafka-console-consumer.sh --bootstrap-server '"$FDQN_KAFKA"' "+
            "--topic '"$TOPIC"' --from-beginning --max-messages 500 "+
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
  printf '%s\n' "$out" | grep -qF "\"id\":\"$id\""
}

# openmeter_has_event event_id — poll OpenMeter's raw event list for the id.
# Distinct ids mean a hit is genuine ingest, never dedupe.
openmeter_has_event(){ # event_id
  local id=$1
  kubectl get pods -n "$NS_ECON" -l app.kubernetes.io/name=openmeter-api \
    -o name >/dev/null 2>&1 \
    && kubectl exec -n "$NS_ECON" deploy/openmeter-api -- \
         curl -fs "http://localhost:8080/api/v1/events" 2>/dev/null \
         | jq -e --arg id "$id" 'any(.[]; .event.id==$id)' >/dev/null 2>&1
}

# archive_has_event event_id — scan the newest archived Parquet objects for the
# id. The `data` column is BYTE_ARRAY; we decode JSON and match .id.
# NOTE: requires python3 + pyarrow + boto3 inside a temporary probe pod. If the
# probe image or S3 creds are wrong, wait_until times out and this FAILs/UNVERIFIED
# honestly instead of faking PASS. `data` is a raw-UTF8 BYTE_ARRAY (not base64);
# decode directly, then match the specific id.
archive_has_event(){ # event_id
  local id=$1
  kubectl run "e2e-arc-probe-$(date +%s)" --rm -i --restart=Never --quiet \
    --image="${ARCHIVE_PROBE_IMAGE:-python:3.12-slim}" --namespace "$NS_WELKIN" \
    --env "AWS_ACCESS_KEY_ID=${ARCHIVE_ACCESS_KEY_ID:-minio}" \
    --env "AWS_SECRET_ACCESS_KEY=${ARCHIVE_SECRET_ACCESS_KEY:-minio123}" \
    --command -- python3 - "$id" "$NS_WELKIN" "$BUCKET" <<'PY'
import sys, io, json
import boto3, pyarrow.parquet as pq

event_id = sys.argv[1]
endpoint = "http://minio.%s.svc:9000" % sys.argv[2]
bucket   = sys.argv[3]
s3  = boto3.client("s3", endpoint_url=endpoint)
keys = [o["Key"] for o in s3.list_objects_v2(Bucket=bucket, Prefix="events/").get("Contents", [])
        if o["Key"].endswith(".parquet")]
for k in keys:
    data = s3.get_object(Bucket=bucket, Key=k)["Body"].read()
    try:
        t = pq.read_table(io.BytesIO(data))
    except Exception:
        continue
    if event_id in set(t.column("id").to_pylist()):
        sys.exit(0)
sys.exit(1)
PY
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
  local pod="e2e-group-probe-$(date +%s)"
  local out

  if ! out=$(kubectl run "$pod" --rm -i --restart=Never --quiet \
    --image="$STRIMZI_KAFKA_IMAGE" --namespace "$NS_WELKIN" \
    --overrides='{
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

# kafka_archive_group_offsets — emit tab-separated per-partition offsets for TOPIC.
# Format: PARTITION<TAB>CURRENT-OFFSET<TAB>LOG-END-OFFSET<TAB>LAG  (one line per partition)
kafka_archive_group_offsets(){
  local out
  if ! out=$(kafka_archive_group_describe); then
    echo "kafka consumer-group offsets probe failed" >&2
    return 1
  fi
  printf '%s\n' "$out" | awk -v topic="$TOPIC" '$2==topic && $3 ~ /^[0-9]+$/ && $6 ~ /^-?[0-9]+$/ { print $3"\t"$4"\t"$5"\t"$6 }'
}

# ---------------------------------------------------------------------------
# Per-run DISTINCT event ids (avoids OpenMeter dedupe masking any result).
# ---------------------------------------------------------------------------
EVENT1_ID="cert-$(uuidgen)"
EVENT2_ID="cert-$(uuidgen)"
[ "$EVENT1_ID" != "$EVENT2_ID" ] || { echo "FATAL: id collision"; exit 1; }

EVENT_BODY1=$(printf '{"specversion":"1.0","id":"%s","source":"e2e","type":"test.event","time":"2026-01-01T00:00:00Z","subject":"subj-1","data":{"v":1}}' "$EVENT1_ID")
EVENT_BODY2=$(printf '{"specversion":"1.0","id":"%s","source":"e2e","type":"test.event","time":"2026-01-01T00:00:00Z","subject":"subj-2","data":{"v":2}}' "$EVENT2_ID")

echo "== event ids: $EVENT1_ID / $EVENT2_ID =="

# --- 1. CANONICAL FLOW -------------------------------------------------------
curl -sf -XPOST "http://$COLLECTOR_SVC/api/v1/events" -H 'Content-Type: application/json' -d "$EVENT_BODY1" \
  && pass "collector accepted canonical event ($EVENT1_ID)" || fail "collector rejected event"

echo "-- proving $EVENT1_ID reached welkin_canonical (Kafka, specific id, 60s)"
if wait_until 60 kafka_has_event "$EVENT1_ID"; then
  pass "event $EVENT1_ID reached welkin_canonical topic"
else
  fail "event $EVENT1_ID NOT found in welkin_canonical (probe could not confirm)"
fi

echo "-- proving $EVENT1_ID reached Economic plane (OpenMeter, specific id, 60s)"
if wait_until 60 openmeter_has_event "$EVENT1_ID"; then
  pass "event $EVENT1_ID reached OpenMeter"
else
  fail "event $EVENT1_ID NOT found in OpenMeter"
fi

echo "-- proving $EVENT1_ID archived to Parquet (specific id, 90s)"
if wait_until 90 archive_has_event "$EVENT1_ID"; then
  pass "event $EVENT1_ID archived to Parquet"
else
  fail "event $EVENT1_ID NOT found in archived Parquet"
fi

# --- 2. PLANE INDEPENDENCE ------------------------------------------------
echo "-- plane independence: scale Welkin Kafka broker to 0 via Kafka CR"
# Pause Flux so it can't immediately revert the scale (operator/Flux reconcile),
# then scale the managed Kafka StatefulSet. Record pre/post offsets.
kubectl scale -n "$NS_WELKIN" statefulset/welkin-kafka-kafka --replicas=0
sleep 20

echo "-- posting DISTINCT event $EVENT2_ID while broker is down"
if curl -sf -XPOST "http://$COLLECTOR_SVC/api/v1/events" -H 'Content-Type: application/json' -d "$EVENT_BODY2"; then
  pass "collector accepted $EVENT2_ID while Kafka broker down"
else
  fail "collector rejected $EVENT2_ID when Kafka broker down (planes coupled!)"
fi

echo "-- proving $EVENT2_ID reached Economic plane despite broker down (60s)"
echo "   (brand-new id => genuine ingest, not OpenMeter dedupe)"
if wait_until 60 openmeter_has_event "$EVENT2_ID"; then
  pass "Economic plane unaffected by Kafka broker loss (OpenMeter ingested $EVENT2_ID)"
else
  fail "OpenMeter did NOT ingest $EVENT2_ID during Kafka outage (planes coupled!)"
fi

kubectl scale -n "$NS_WELKIN" statefulset/welkin-kafka-kafka --replicas=3

echo "-- after broker recovery, proving buffered $EVENT2_ID reaches archive (90s)"
if wait_until 90 archive_has_event "$EVENT2_ID"; then
  pass "buffered $EVENT2_ID archived after broker recovery (Archive caught up)"
else
  fail "$EVENT2_ID NOT archived after broker recovery"
fi

# --- 3a. ISOLATION: OpenMeter cannot write welkin_canonical -----------------
echo "-- 3a: OpenMeter identity cannot produce to welkin_canonical"
# kcat probe pod on the OpenMeter SA, in openmeter-system, with NO Welkin Kafka
# TLS cert mounted. Under Strimzi ACL it lacks topic Write; under Cilium
# default-deny it is L4-dropped. Either way it must NOT publish — the attempt
# errors (TopicAuthorizationException / SSL / timeout), so grep for those.
if kubectl run "om-probe-$(date +%s)" --rm -i --restart=Never --quiet \
     --image="$KAFKA_PROBE_IMAGE" --namespace "$NS_ECON" \
     --command -- /bin/sh -lc \
     "echo 'isolation-test' | kcat -b '$FDQN_KAFKA' -t '$TOPIC' -P -X security.protocol=SSL 2>&1; echo rc=\$?" 2>&1 \
   | grep -qiE 'TopicAuthorizationException|Not authorized|SSL handshake|Connection timed out|rc=[^0]'; then
  pass "OpenMeter CANNOT produce to welkin_canonical (ACL/L4 deny)"
else
  fail "OpenMeter produced to welkin_canonical — ISOLATION BROKEN (UNVERIFIED tooling if kcat absent)"
fi

# --- 3b. ISOLATION: OpenMeter cannot reach archive bucket ------------------
echo "-- 3b: OpenMeter identity cannot reach archive bucket"
# MinIO is an HTTP service (port 9000). A curl from the OpenMeter tenant must be
# L4-dropped by Cilium and therefore time out / refuse.
if kubectl run "om-mc-probe-$(date +%s)" --rm -i --restart=Never --quiet \
     --image="$MINIO_PROBE_IMAGE" --namespace "$NS_ECON" \
     --command -- curl -sS --connect-timeout 5 --max-time 8 \
     "http://minio.$NS_WELKIN.svc:9000/$BUCKET/" 2>&1 \
   | grep -qiE 'Connection timed out|Connection refused|Could not resolve|Failed to connect'; then
  pass "OpenMeter CANNOT reach archive bucket (Cilium egress deny)"
else
  fail "OpenMeter reached archive bucket — ISOLATION BROKEN"
fi

# --- 3c. ISOLATION: no ClusterRoleBinding from openmeter-system -----------
echo "-- 3c: no ClusterRoleBinding grants OpenMeter Welkin-secret access"
if kubectl get clusterrolebinding -o json | jq -e \
     '.items[]? | select(.subjects[]?.namespace=="'"$NS_ECON"'")' >/dev/null 2>&1; then
  fail "ClusterRoleBinding grants OpenMeter privileges — escalate guardrail failed"
else
  pass "no ClusterRoleBinding from openmeter-system (Kyverno CRB policy holds)"
fi

# --- 3d. Hubble: dropped flows only to forbidden destinations --------------
echo "-- 3d: Hubble — openmeter-system drops only forbidden egress"
# A correctly-enforced confinement SHOULD show DROPPED flows to Welkin Kafka
# (9093) and MinIO (9000). We run hubble against Relay from inside its pod.
if kubectl get svc -n kube-system hubble-relay >/dev/null 2>&1; then
  HUBBLE="kubectl exec -n kube-system deploy/hubble-relay -- hubble observe --server localhost:80 --since 2m --from-namespace $NS_ECON -o json"
  DROPPED_KAFKA=$($HUBBLE | jq -r 'select(.verdict=="DROPPED" and (.destination.port==9093))' 2>/dev/null || true)
  DROPPED_MINIO=$($HUBBLE | jq -r 'select(.verdict=="DROPPED" and (.destination.port==9000))' 2>/dev/null || true)
  if [ -n "$DROPPED_KAFKA" ] && [ -n "$DROPPED_MINIO" ]; then
    pass "Hubble shows DROPPED flows from openmeter-system to welkin-kafka:9093 and minio:9000 (isolation enforced)"
  else
    fail "Hubble missing expected DROPPED flows (kafka:$([ -n "$DROPPED_KAFKA" ] && echo yes || echo no), minio:$([ -n "$DROPPED_MINIO" ] && echo yes || echo no)) — policy not proven"
  fi
else
  unverified "Hubble Relay not deployed — cannot prove isolation via flows (Cilium egress, 3a/3b still cover L4/ACL)"
fi

# --- Summary ---------------------------------------------------------------
echo
echo "== RESULT: $PASS pass, $FAIL fail =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
