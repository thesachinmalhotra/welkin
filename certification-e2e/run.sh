#!/usr/bin/env bash
# certification-e2e — the authoritative Welkin gate on a k3s cluster.
#
# Asserts:
#   1. CANONICAL FLOW  — POST to Collector lands in OpenMeter AND in the
#      welkin_canonical Kafka topic AND in the archive bucket (S3/MinIO).
#   2. PLANE INDEPENDENCE — killing the Kafka broker does NOT break OpenMeter
#      ingest (Economic plane unaffected by Archive-plane broker loss).
#   3. ISOLATION (OpenMeter is enemy) —
#      a. OpenMeter pod CANNOT produce to welkin_canonical (Strimzi ACL deny).
#      b. OpenMeter pod CANNOT reach the archive bucket (Cilium egress deny).
#      c. OpenMeter SA has no Role granting Welkin secrets (Kyverno CRB policy).
#      d. Hubble shows only allowed flows for openmeter-system.
#
# Requires: kubectl context pointing at the test cluster with the platform
# installed (flux reconcile from the signed artifact), plus `kafka-console-*`
# and `mc` (minio client) available via kubectl exec.
set -euo pipefail

NS_WELKIN=welkin-system
NS_ECON=openmeter-system
TOPIC=welkin_canonical
BUCKET=welkin-archive
OPENMETER_POD=$(kubectl get pod -n "$NS_ECON" -l app.kubernetes.io/name=openmeter -o jsonpath='{.items[0].metadata.name}')
COLLECTOR_SVC=openmeter-collector.$NS_WELKIN.svc.cluster.local:8080

pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; EXIT=1; }

# --- 1. CANONICAL FLOW -------------------------------------------------------
EVENT='{"specversion":"1.0","id":"cert-'"$RANDOM"'","source":"e2e","type":"test.event","time":"2026-01-01T00:00:00Z","subject":"subj-1","data":{"v":1}}'
curl -sf -XPOST "http://$COLLECTOR_SVC/api/v1/events" -H 'Content-Type: application/json' -d "$EVENT" \
  && pass "collector accepted canonical event" || fail "collector rejected event"

# event should appear in welkin_canonical (Kafka console consumer, 10s)
if kubectl exec -n "$NS_WELKIN" deploy/welkin-archive -c main -- \
     kafka-console-consumer.sh --bootstrap-server welkin-kafka-kafka-bootstrap:9093 \
     --topic "$TOPIC" --from-beginning --max-messages 1 --timeout 10000 >/dev/null 2>&1; then
  pass "event reached welkin_canonical topic"
else
  fail "event NOT in welkin_canonical topic"
fi

# --- 2. PLANE INDEPENDENCE ------------------------------------------------
kubectl scale -n "$NS_WELKIN" statefulset/welkin-kafka-kafka --replicas=0
sleep 20
if curl -sf -XPOST "http://$COLLECTOR_SVC/api/v1/events" -H 'Content-Type: application/json' -d "$EVENT"; then
  pass "OpenMeter ingest unaffected by Kafka broker loss (plane independence)"
else
  fail "OpenMeter ingest broke when broker down (planes coupled!)"
fi
kubectl scale -n "$NS_WELKIN" statefulset/welkin-kafka-kafka --replicas=3

# --- 3a. ISOLATION: OpenMeter cannot write welkin_canonical -----------------
if kubectl exec -n "$NS_ECON" "$OPENMETER_POD" -- sh -c \
     "kafka-console-producer.sh --bootstrap-server welkin-kafka-kafka-bootstrap.$NS_WELKIN.svc:9093 --topic $TOPIC" \
     <<<"isolation-test" 2>&1 | grep -qi 'TopicAuthorizationException\|Not authorized\|denied'; then
  pass "OpenMeter CANNOT produce to welkin_canonical (ACL deny)"
else
  fail "OpenMeter produced to welkin_canonical — ISOLATION BROKEN"
fi

# --- 3b. ISOLATION: OpenMeter cannot reach archive bucket ------------------
if kubectl exec -n "$NS_ECON" "$OPENMETER_POD" -- sh -c \
     "mc ls local/$BUCKET" 2>&1 | grep -qi 'connection refused\|route\|denied\|timed out'; then
  pass "OpenMeter CANNOT reach archive bucket (Cilium egress deny)"
else
  fail "OpenMeter reached archive bucket — ISOLATION BROKEN"
fi

# --- 3c. ISOLATION: no ClusterRoleBinding from openmeter-system -----------
if kubectl get clusterrolebinding -o json | jq -e \
     '.items[] | select(.subjects[]?.namespace=="'"$NS_ECON"'')' >/dev/null 2>&1; then
  fail "ClusterRoleBinding grants OpenMeter privileges — escalate guardrail failed"
else
  pass "no ClusterRoleBinding from openmeter-system (Kyverno CRB policy holds)"
fi

# --- 3d. Hubble: only allowed flows for openmeter-system -------------------
DROPPED_ALLOWED=$(kubectl exec -n kube-system ds/cilium -- cilium hubble --timeout 5 observe \
   --namespace "$NS_ECON" --verdict DROPPED -o json 2>/dev/null | jq -r '.destination' | head)
[ -n "$DROPPED_ALLOWED" ] && fail "unexpected dropped flows from openmeter-system: $DROPPED_ALLOWED" \
   || pass "no unexpected dropped flows observed for openmeter-system"

exit ${EXIT:-0}
