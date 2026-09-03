# T5 Runtime Compatibility Matrix

T5 uses an intentionally frozen runtime matrix so certification does not drift
because a tool installer or controller release changes underneath the test.

| Component | T5 version | Compatibility basis |
| --- | --- | --- |
| Kubernetes / Kind node image | 1.32.8 | Kind node image is pinned by digest in the workflow. |
| Cilium | 1.17.0 | Cilium 1.17 documents Kubernetes 1.29, 1.30, 1.31, and 1.32 as e2e-tested/guaranteed compatible. |
| Flux CLI + controllers | 2.7.5 | Flux 2.7 documents Kubernetes 1.32 as supported from 1.32.0. CLI and controller manifests are installed at the same pinned version. |
| Strimzi | 0.45.0 | Strimzi 0.45 supports Kubernetes 1.25+ and Kafka 3.9.0. |
| Apache Kafka | 3.9.0 | Kafka version selected by the Strimzi 0.45 Kafka CR. |

## T5-06 / T5-07 — deterministic Flux installation

T5 does not execute the mutable `fluxcd.io/install.sh`. The workflow downloads
the Flux 2.7.5 Linux amd64 release archive, verifies its published SHA-256
checksum, installs that exact CLI, and asks the CLI to install controller
manifests for the same 2.7.5 release.

This keeps the CLI, generated controller manifests, and certification runtime
on one explicit Flux release.

## T5-08 — Kubernetes / Flux / Cilium lock

Kubernetes 1.32.8 is retained because Cilium 1.17 explicitly lists Kubernetes
1.32 among its e2e-tested compatible versions. Flux 2.7.5 is selected because
the Flux 2.7 documentation explicitly supports Kubernetes 1.32, whereas the
Flux 2.8/2.9 documentation starts its supported matrix at Kubernetes 1.33.
This avoids solving one compatibility problem by introducing another.

## T5-09 / T5-10 — Strimzi ZooKeeper boundary

T5 intentionally freezes Strimzi 0.45.0 with Kafka 3.9.0 and the existing
ZooKeeper-based topology. Strimzi 0.45 identifies itself as the **last minor
release with ZooKeeper support** and instructs users to migrate to KRaft before
upgrading to 0.46 or newer. Strimzi 0.46 removes both ZooKeeper cluster support
and ZooKeeper-to-KRaft migration support.

Therefore, T5 does **not** perform a KRaft migration. Migration is a separate
post-T5 architectural change and must not be smuggled into the certification
hardening work.

Primary upstream references:

- Flux 2.7 installation and Kubernetes compatibility: https://v2-7.docs.fluxcd.io/flux/installation/
- Flux 2.8 installation/compatibility boundary: https://v2-8.docs.fluxcd.io/flux/installation/
- Flux 2.7.5 release: https://github.com/fluxcd/flux2/releases/tag/v2.7.5
- Cilium 1.17 Kubernetes compatibility: https://docs.cilium.io/en/v1.17/network/kubernetes/compatibility/
- Strimzi 0.45.0 release: https://github.com/strimzi/strimzi-kafka-operator/releases/tag/0.45.0
- Strimzi 0.46.0 release: https://github.com/strimzi/strimzi-kafka-operator/releases/tag/0.46.0