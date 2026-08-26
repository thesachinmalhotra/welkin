package main

// Canonical meter catalog. Consumed by openmeter.cue via
// helmValues.config.meters. Add meters here; they are applied with the
// platform bundle.
meterCatalog: [{
  slug:          "kubernetes_pod_exec_time"
  description:   "Kubernetes pod exec time"
  eventType:     "kube-pod-exec-time"
  valueProperty: "$.duration_seconds"
  aggregation:   "SUM"
  groupBy: {
    pod_namespace: "$.pod_namespace"
    pod_name:      "$.pod_name"
  }
}]
