# T5 Audit Status

Continuity record for the T5 Kind certification work and the upstream-vs-Welkin overengineering audit.

## Audit rule

1. Identify the upstream primitive.
2. Identify the smallest composition required by Welkin.
3. Audit the repository against that upstream mechanism.
4. Record exact drift and classification.
5. Do not implement audit findings until the audit is complete and explicitly approved.

Default rule: if a line cannot be justified as Welkin-specific, presume it unnecessary until proven otherwise.

## Work plan

| Wave | Item | Audit target | Status |
| --- | --- | --- | --- |
| W1 | 1 | Kind + Kubernetes bootstrap | DONE |
| W1 | 2 | Cilium installation/configuration | DONE |
| W1 | 3 | Cilium network-policy architecture | DONE |
| W1 | 4 | Strimzi/Kafka networking & lifecycle | NEXT |
| W2 | 5 | OpenMeter core deployment | NOT STARTED |
| W2 | 6 | OpenMeter/Benthos Collector | NOT STARTED |
| W2 | 7 | Archive consumer / Kafka -> Parquet | NOT STARTED |
| W2 | 8 | MinIO/Object Storage | NOT STARTED |
| W3 | 9 | Flux bootstrap/reconciliation | NOT STARTED |
| W3 | 10 | Kyverno/admission | NOT STARTED |
| W3 | 11 | T5 CI workflow | NOT STARTED |
| W3 | 12 | T5 runtime certification scripts | NOT STARTED |
| W4 | 13 | Version/matrix strategy | NOT STARTED |
| W4 | 14 | Readiness/dependency orchestration | NOT STARTED |
| W4 | 15 | End-to-end data/control-plane graph | NOT STARTED |
| W4 | 16 | Final cross-cutting overengineering audit | NOT STARTED |

Only one item is audited at a time. W1-04 is the next item.

## W1-01 — Kind + Kubernetes bootstrap

Upstream mechanisms verified: Kind supports disabling the default CNI and disabling kube-proxy; the Kubernetes version is selected by the Kind node image; digest pinning is appropriate; Cilium's Kind guidance uses a no-default-CNI topology and expects nodes to remain NotReady until Cilium is installed.

Welkin is aligned on topology, no-default-CNI, kube-proxy-free mode, pinned node image, matching kubectl version, Kind config, and Kind action version.

Finding: the only concrete drift identified was wait: 120s in the Kind action while the cluster intentionally has no CNI yet. Cilium's own CI uses wait: 0 for this bootstrap shape.

Classification: SIMPLIFY.

No implementation change was made during the audit.

## W1-02 — Cilium installation/configuration

The direct Cilium bootstrap is justified because Kind starts without a CNI and kube-proxy. Flux cannot be relied upon to provide the first CNI before the cluster is usable.

Native mechanisms verified include Kubernetes IPAM, kube-proxy replacement with the Kubernetes API endpoint, Hubble Relay for the existing certification evidence path, and WireGuard encryption.

The production bundle already contained broader Cilium configuration before the T5 work; those pre-existing capabilities are not automatically counted as T5 overengineering.

Findings:

- Direct Cilium bootstrap: KEEP.
- Kubernetes IPAM: KEEP.
- Kube-proxy replacement/API endpoint: KEEP.
- One operator replica for the ephemeral T5 cluster: JUSTIFIED WELKIN-SPECIFIC.
- Hubble Relay: KEEP for the current certification evidence path.
- Explicit Hubble enablement: SIMPLIFY because it is redundant with the pinned Cilium chart default.
- Hubble UI: DELETE candidate because the T5 certification path does not use it.
- Envoy configuration enablement: DELETE/INVESTIGATE candidate; no demonstrated L7 Kafka policy dependency was found.
- Duplicate Cilium configuration between the production bundle and CI bootstrap: SIMPLIFY; reduce source-of-truth duplication.
- OCI-vs-Helm representation: both are official upstream mechanisms, but maintaining two representations should be simplified if one source can express the required semantics.

No implementation change was made during the audit.

## W1-03 — Cilium network-policy architecture

The fundamental policy model is native Cilium L3/L4 identity-based enforcement: endpoint selection plus fromEndpoints/toEndpoints, with stateful reply handling.

Welkin currently has a baseline CiliumClusterwideNetworkPolicy for DNS, Kubernetes API, and health/host egress; a CiliumClusterwideNetworkPolicy implementing default deny; and workload-specific L3/L4 policies for OpenMeter, Kafka, MinIO, Collector, and Archive paths.

The default-deny mechanism itself is correct and should remain.

Finding: the namespace-wide default-deny selector was narrowed during T5 to welkin-system and openmeter-system, but this still selects every endpoint in those namespaces, including platform/operator pods. This creates the broad-deny -> discover blocked dependency -> add another allow-policy pattern that the audit is specifically intended to eliminate where upstream ownership already provides the primitive.

The comment claiming that platform control-plane namespaces remain outside the policy is only partially accurate: other namespaces are excluded, but control-plane/operator pods inside the selected namespaces are not.

Destination-side policies such as Kafka and MinIO ingress are UNRESOLVED / KEEP PENDING OWNER AUDIT. Their necessity cannot be judged correctly until the owning upstream controllers are audited. W1-04 specifically determines whether Strimzi already owns the relevant Kafka listener policy.

No implementation change was made during the audit.

## Repository checkpoint

Branch: fix/t5-kind-certification

Remote: origin/fix/t5-kind-certification

Latest existing T5 commits before this checkpoint include:

- 885a5be — align Kind Cilium bootstrap with upstream
- e559e94 — correct Cilium API endpoint jsonpath
- 9a5fc3f — close runtime probe and policy gaps

This checkpoint also records the staged Flux artifact/lifecycle-boundary work that is being committed alongside this continuity document.

## Continuation constraints

- Do not jump to W2, W3, or W4 while W1-04 is pending.
- Do not make implementation changes while performing an audit.
- Do not run GitHub Actions or CI unless explicitly approved.
- Do not push speculative fixes.
- Use upstream documentation/source first, then inspect the repository.
- Compose upstream primitives; do not build new DNA.
