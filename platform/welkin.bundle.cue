package main

// Timoni module root for the Welkin platform. Lets `timoni bundle` compile
// all value files (collector, openmeter, postgres, archive, minio, infra) as
// one package so the bundle can reference them.
module: {
	name:    "welkin"
	version: "0.0.0"
}

// Welkin Product — the immutable definition of what a Welkin release IS.
// Component versions, product semantics and defaults live here. Nothing in
// this file is environment-specific or runtime-injectable.
//
// Environment configuration lives in platform/runtime/welkin.runtime.cue.

product: {
	charts: {
		fluxAioVersion:    "2.9.4-0"
		fluxModuleVersion: "2.9.4-0"
		openmeterVersion:  "1.0.0-beta.232"
		collectorVersion:  "1.0.0-beta.232"
		postgresqlVersion: "16.1.2"
		// Substrate (infra) plane — portable, cloud-agnostic.
		strimziVersion: "0.45.0"
		ciliumVersion:  "1.17.16"
		kyvernoVersion: "1.14.0"
	}

	// Derived from the collector chart version — single source, no drift.
	collectorImage: {
		repository: "ghcr.io/openmeterio/benthos-collector"
		tag:        "v\(charts.collectorVersion)"
	}

	// Archive plane semantics (product defaults, not environment knobs).
	archive: {
		batchCount:  250
		batchPeriod: "15s"
	}

	// Canonical CloudEvent contract version. The runtime enforcement is the
	// collector's inline json_schema (DECISION A); this value is what it pins.
	canonical: {
		specversion: "1.0"
	}
}

// Welkin Runtime — the environment API.
// Answers exactly one question: "how does this Welkin release run HERE?"
// Only genuinely environment-specific values: namespaces, external endpoints,
// credentials, storage locations, capacity. Product definition lives in
// platform/product.cue.
//
// SECURITY: every secret-bearing field is a SOPS-encrypted injection point.
// Plaintext defaults below are dev-only and MUST be overridden via SOPS in
// any real cluster (see platform/flux/sops/). "changeme" is a canary that
// fails admission via Kyverno if it ever reaches a non-dev namespace.

runtime: {
	// Trust domains. OpenMeter is an untrusted tenant, confined to its own
	// namespace; Welkin-owned control plane + data plane share welkin-system.
	welkinNamespace:   *"welkin-system" | string @timoni(runtime:string:WELKIN_NAMESPACE)
	economicNamespace: *"openmeter-system" | string @timoni(runtime:string:ECONOMIC_NAMESPACE)

	openmeter: {
		url:   *"http://openmeter-api.\(economicNamespace).svc.cluster.local" | string @timoni(runtime:string:OPENMETER_URL)
		token: *"changeme" | string @timoni(runtime:string:OPENMETER_TOKEN)
	}

	postgres: {
		host:             *"welkin-postgres" | string @timoni(runtime:string:POSTGRES_HOST)
		port:             *"5432" | string @timoni(runtime:string:POSTGRES_PORT)
		username:         *"application" | string @timoni(runtime:string:POSTGRES_USERNAME)
		password:         *"application" | string @timoni(runtime:string:POSTGRES_PASSWORD)
		database:         *"application" | string @timoni(runtime:string:POSTGRES_DATABASE)
		postgresPassword: *"application" | string @timoni(runtime:string:POSTGRES_ADMIN_PASSWORD)
	}

	// Welkin-owned canonical event bus. Strimzi Kafka, Welkin-owned topic.
	// OpenMeter has NO ACL to this topic (see platform/infra/strimzi).
	kafka: {
		bootstrap:       *"welkin-kafka-kafka-bootstrap.\(welkinNamespace).svc.cluster.local:9093" | string @timoni(runtime:string:KAFKA_BOOTSTRAP)
		topic:           *"welkin_canonical" | string @timoni(runtime:string:KAFKA_TOPIC)
		// Strimzi User Operator emits a Secret with the same name as the KafkaUser.
		collectorSecret: *"welkin-collector-kafka" | string @timoni(runtime:string:KAFKA_COLLECTOR_SECRET)
		archiveSecret:   *"welkin-archive-kafka" | string @timoni(runtime:string:KAFKA_ARCHIVE_SECRET)
	}

	archive: {
		endpoint:        *"http://minio.\(welkinNamespace).svc.cluster.local:9000" | string @timoni(runtime:string:ARCHIVE_S3_ENDPOINT)
		bucket:          *"welkin-archive" | string @timoni(runtime:string:ARCHIVE_S3_BUCKET)
		region:          *"us-east-1" | string @timoni(runtime:string:ARCHIVE_S3_REGION)
		forcePathStyle:  *true | bool @timoni(runtime:string:ARCHIVE_S3_FORCE_PATH_STYLE)
		// S3 creds are NOT inline here — they come from the SOPS-encrypted
		// `welkin-archive-s3` Secret via envFrom, so they never render plaintext.
	}
}

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

openmeterValues: {
	repository: url: "oci://ghcr.io/openmeterio/helm-charts"
	chart: {
		name:    "openmeter"
		version: product.charts.openmeterVersion
	}
	sync: {
		targetNamespace: runtime.economicNamespace
		createNamespace: true
		timeout:         15
	}
	helmValues: {
		// Secrets (OpenMeter API key + Stripe key) arrive via SOPS-encrypted
		// Secrets. OpenMeter reads OPENMETER_API_KEY (its server key) and
		// STRIPE_API_KEY for the economic plane.
		envFrom: [
			{secretRef: {name: "welkin-openmeter-token"}},
			{secretRef: {name: "welkin-stripe"}},
		]
		// postgresql.enabled is universally false — the chart's mergeOverwrite
		// would replace our sslmode=disable DSN with a TLS-requiring one, so we
		// disable the subchart entirely and own Postgres as a Welkin economic-plane
		// component (platform/economic/postgres.cue). Both dev and prod topologies
		// now use the same wiring: postgresql disabled, DSN from runtime.inject.
		svix: {
			enabled: false
		}
		redis: {
			enabled: false
		}
		// postgresql is always disabled: the chart's mergeOverwrite would otherwise
		// replace our sslmode=disable DSN with a TLS-requiring one.
		postgresql: {
			enabled: false
		}
		// ponytail: scale off-path workers to zero for kind/CI footprint; raise
		// when running real workloads (balance/billing/notification are off the
		// ingestion path — certification only needs api+kafka+clickhouse+pg)
		balanceWorker: {
			replicaCount: 0
		}
		billingWorker: {
			replicaCount: 0
		}
		notificationService: {
			replicaCount: 0
		}

		// ponytail: single-node Kafka for CI — cuts ~400MB RAM vs default 3 replicas.
		// NOTE: this is OpenMeter's INTERNAL Kafka (economic plane only). It is
		// separate from Welkin's welkin_canonical bus (Strimzi, welkin-system).
		kafka: {
			controller: {
				replicaCount: 1
			}
		}
		config: {
			// Use URL only — params left empty so IsEmpty() is true and AsURL()
			// returns the URL directly. This avoids the uint16 Port decode that
			// was failing with "" even when port 5432 was set.
			postgres: {
				url:         "postgres://\(runtime.postgres.username):\(runtime.postgres.password)@\(runtime.postgres.host):\(runtime.postgres.port)/\(runtime.postgres.database)?sslmode=disable"
				autoMigrate: "migration"
			}
			meters: meterCatalog
		}
	}
}

// Welkin-owned development Postgres (Economic Plane dependency).
// Confined to economicNamespace (OpenMeter's trust domain) — Welkin control
// plane (collector/archive) has no credentials to it.
// The pinned chart version (16.1.2) matches the Chart.lock at
// openmeter v1.0.0-beta.232 and uses bitnamilegacy image repos
// per upstream image-move (openmeterio/openmeter#4172).
postgresValues: {
	repository: url: "oci://registry-1.docker.io/bitnamicharts"
	chart: {
		name:    "postgresql"
		version: product.charts.postgresqlVersion
	}
	sync: {
		targetNamespace: runtime.economicNamespace
		createNamespace: true
		timeout:         15
	}
	helmValues: {
		fullnameOverride: "welkin-postgres"
		auth: {
			username:         runtime.postgres.username
			password:         runtime.postgres.password
			database:         runtime.postgres.database
			postgresPassword: runtime.postgres.postgresPassword
		}
		image: repository: "bitnamilegacy/postgresql"
		volumePermissions: image: repository: "bitnamilegacy/os-shell"
		metrics: enabled: false
	}
}

collectorValues: {
	repository: url: "oci://ghcr.io/openmeterio/helm-charts"
	chart: {
		name:    "benthos-collector"
		version: product.charts.collectorVersion
	}
	sync: {
		targetNamespace: runtime.welkinNamespace
		createNamespace: true
	}
	helmValues: {
		// Match upstream quickstart naming so the Service DNS name is
		// openmeter-collector.<namespace>.svc.
		fullnameOverride: "openmeter-collector"
		nameOverride: "openmeter-collector"

		// Secrets (OpenMeter API key) arrive via the SOPS-encrypted Secret.
		envFrom: [{secretRef: {name: "welkin-openmeter-token"}}]

		image: product.collectorImage

		// Expose the event input (container port "http" = 8080) as a Service.
		service: {
			enabled: true
			port:    8080
		}

		// Persistent volume for the sqlite buffer (/data).
		storage: enabled: false

		// ponytail: chart's rbac.yaml has duplicate `subjects:` key (line 23-24)
		// in the ClusterRoleBinding — Flux's Kustomize post-renderer rejects it
		// while `helm install` silently ignores it. Disable the chart's RBAC and
		// let the ServiceAccount run with namespace-scoped permissions; the
		// http-server preset only needs the Secret, not pod/list.
		rbac: create: false

		openmeter: {
			url: runtime.openmeter.url
			// API key is injected at runtime from the SOPS-encrypted
			// `welkin-openmeter-token` Secret via envFrom (see helmValues.envFrom).
			token: "${OPENMETER_API_KEY:-dev-key}"
		}

		// Mount the Strimzi TLS user Secret for the welkin_canonical producer.
		extraVolumes: [{
			name:      "kafka-tls"
			secret: {secretName: runtime.kafka.collectorSecret}
		}]
		extraVolumeMounts: [{
			name:      "kafka-tls"
			mountPath: "/etc/kafka/tls"
			readOnly: true
		}]

		// The chart treats `config` as all-or-nothing (config > configFile >
		// preset), so input, validation, buffer and outputs are composed here,
		// following upstream's documented manual configuration shape.
		//
		// SYNC POLICY: This config mirrors the pinned upstream preset
		// `http-server` from benthos-collector chart v1.0.0-beta.232.
		// Check upstream release notes on every chart version bump.
		config: {
			logger: {
				level:  "${LOG_LEVEL:DEBUG}"
				format: "${LOG_FORMAT:json}"
				static_fields: {
					service: "openmeter-collector"
				}
			}

			// ponytail: matches upstream http-server preset shutdown_timeout
			shutdown_timeout: "10s"

			http: {
				enabled:         true
				address:         "0.0.0.0:4195"
				debug_endpoints: false
			}

			input: {
				http_server: {
					address:       "0.0.0.0:8080"
					path:          "/api/v1/events"
					allowed_verbs: ["POST"]
					timeout:       "10s"
					sync_response: {
						status: "${! meta(\"http_status_code\").or(\"204\") }"
						headers: {
							"Content-Type": "${! meta(\"content_type\").or(\"application/json\") }"
						}
					}
				}
				processors: [
					{
						metric: {
							type:  "counter"
							name:  "openmeter_event_received"
							value: "1"
						}
					},
					{
						label: "validation"
					// Runtime enforcement of the Welkin-canonical CloudEvent.
					// This inline schema is the single source of validation (no
					// separate spec file to drift from).
						json_schema: {
							schema: "{\"type\":\"object\",\"required\":[\"specversion\",\"id\",\"source\",\"type\",\"time\",\"subject\",\"data\"],\"properties\":{\"specversion\":{\"type\":\"string\",\"const\":\"1.0\"},\"id\":{\"type\":\"string\",\"minLength\":1},\"source\":{\"type\":\"string\",\"minLength\":1},\"type\":{\"type\":\"string\",\"minLength\":1},\"time\":{\"type\":\"string\",\"format\":\"date-time\"},\"subject\":{\"type\":\"string\",\"minLength\":1},\"data\":{\"type\":\"object\"}}}"
						}
					},
					{
					label: "canonical_mapping"
					// DECISION A — Canonicalize ONCE at the Collector boundary.
					// Downstream (OpenMeter, Archive) never re-translates. Pins
					// specversion to the product contract so producers can't drift.
					mapping: """
						root.specversion = "\(product.canonical.specversion)"
						root.source = this.source
						root.subject = this.subject
						root.type = this.type
						root.time = this.time
						root.id = this.id
						root.data = this.data
						"""
					},
					{
						catch: [{
							log: {
								level:          "ERROR"
								message:        "schema validation failed due to: ${!error()}"
								fields_mapping: "root = this"
							}
						}, {
							mapping: """
								meta http_status_code = "400"
								meta content_type = "application/problem+json"

								root = {
									"type": "about:blank",
									"title": "Bad Request",
									"status": 400,
									"detail": "invalid event: %s".format(error()),
								}
								"""
						}, {
							sync_response: {}
						}, {
							mapping: "root = deleted()"
						}]
					},
					{
						mapping: """
							meta http_status_code = "204"
							"""
					},
					{
						sync_response: {}
					},
				]
			}

			buffer: {
				sqlite: {
					path: "./buffer.db"
					post_processors: [{
						label: "buffer_split_batch"
						split: {size: 100}
					}]
				}
			}

			// Fan-out to both planes. No drop_on — Kafka failure backpressures
			// the collector and retries; the record stays buffered until the
			// archive handoff is durable. OpenMeter may process the current
			// message, but subsequent ingestion stalls until Kafka recovers.
			output: {
				label: "collector"
				broker: {
					pattern: "fan_out"
					outputs: [
						{
							label: "openmeter"
							drop_on: {
								error:          false
								error_patterns: ["Bad Request"]
								output: {
									http_client: {
										url:  "\(runtime.openmeter.url)/api/v1/events"
										verb: "POST"
										headers: {
											// Bearer token injected from the `welkin-openmeter-token`
											// Secret via envFrom. Default keeps local gates running.
											Authorization: "Bearer ${OPENMETER_API_KEY:-dev-key}"
											"Content-Type": "application/json"
										}
										timeout:            "30s"
										retry_period:       "15s"
										retries:            3
										max_retry_backoff:  "1m"
										max_in_flight:      64
										batch_as_multipart: false
										drop_on: ["400"]
										batching: {
											count:  100
											period: "1s"
											processors: [{
												metric: {
													type:  "counter"
													name:  "openmeter_events_sent"
													value: "1"
												}
											}, {
												archive: {format: "json_array"}
											}]
										}
										dump_request_log_level: "DEBUG"
									}
								}
							}
						},
						{
							label: "welkin_canonical"
							// DECISION B — Archive plane consumes welkin_canonical
							// (Strimzi, welkin-system). OpenMeter has NO ACL to this
							// topic. TLS client cert issued by Strimzi User Operator,
							// mounted at /etc/kafka/tls.
							kafka_franz: {
								seed_brokers: [runtime.kafka.bootstrap]
								topic:        runtime.kafka.topic
								tls: {
									enabled:          true
									root_cas_file:    "/etc/kafka/tls/ca.crt"
									client_certs_file: "/etc/kafka/tls/user.crt"
									client_key_file:   "/etc/kafka/tls/user.key"
								}
								metadata_max_age: "1m"
								batching: {
									count:  100
									period: "1s"
									processors: [{
										metric: {
											type:  "counter"
											name:  "welkin_canonical_events_produced"
											value: "1"
										}
									}]
								}
							}
						},
					]
				}
			}

			metrics: {
				prometheus: {
					add_process_metrics: true
				}
			}
		}
	}
}

// DECISION B — Archive plane is a SEPARATE process from the Collector.
// It is the only consumer of welkin_canonical (Welkin-owned Strimzi topic) and
// the only writer to the archive bucket. OpenMeter never touches either.
// Plane independence: Collector/OpenMeter failures cannot block Archive and
// vice-versa: Archive is decoupled after Kafka durable handoff; the Collector
// fan_out has no drop_on on the Kafka branch, so Kafka unavailability backpressures ingestion.
archiveValues: {
	repository: url: "oci://ghcr.io/openmeterio/helm-charts"
	chart: {
		name:    "benthos-collector"
		version: product.charts.collectorVersion
	}
	sync: {
		targetNamespace: runtime.welkinNamespace
		createNamespace: true
	}
	helmValues: {
		fullnameOverride: "welkin-archive"
		nameOverride: "welkin-archive"

		// S3 creds arrive via the SOPS-encrypted Secret.
		envFrom: [{secretRef: {name: "welkin-archive-s3"}}]

		image: product.collectorImage

		service: {enabled: false}

		storage: enabled: false

		// Archive runs read-only on its topic; no cluster RBAC needed.
		rbac: create: false

		// Strimzi TLS user Secret for the welkin_canonical consumer.
		extraVolumes: [{
			name:      "kafka-tls"
			secret: {secretName: runtime.kafka.archiveSecret}
		}]
		extraVolumeMounts: [{
			name:      "kafka-tls"
			mountPath: "/etc/kafka/tls"
			readOnly: true
		}]

		config: {
			logger: {
				level:  "${LOG_LEVEL:DEBUG}"
				format: "${LOG_FORMAT:json}"
				static_fields: {service: "welkin-archive"}
			}
			shutdown_timeout: "10s"

			http: {enabled: false}

			input: {
				kafka_franz: {
					seed_brokers: [runtime.kafka.bootstrap]
					topics:       [runtime.kafka.topic]
					group_id:     "welkin-archive"
					tls: {
						enabled:           true
						root_cas_file:     "/etc/kafka/tls/ca.crt"
						client_certs_file: "/etc/kafka/tls/user.crt"
						client_key_file:   "/etc/kafka/tls/user.key"
					}
					consumer_group: {
						// T5 uses one in-flight record per partition so a storage failure cannot
						// advance a later offset ahead of the failed archive write.
						checkpoint_limit:      1
						session_timeout:       "60s"
						heartbeat_interval:    "3s"
						rebalance_timeout:     "60s"
					}
					batching: {
						count:  100
						period: "1s"
					}
				}
				processors: [
					{
						metric: {
							type:  "counter"
							name:  "welkin_archive_events_consumed"
							value: "1"
						}
					},
				]
			}

			// Archive durability: no drop_on — S3 failure backpressures and
			// retries via Kafka consumer-group offset. The record stays in the
			// topic until the object is durably persisted.
			output: {
				aws_s3: {
					bucket:                runtime.archive.bucket
					path:                  "events/${!timestamp_unix()}-${!uuid_v4()}.parquet"
					endpoint:              runtime.archive.endpoint
					force_path_style_urls: runtime.archive.forcePathStyle
					region:                runtime.archive.region
					credentials: {
						// Injected from the `welkin-archive-s3` Secret via envFrom.
						id:     "${ARCHIVE_ACCESS_KEY_ID:-minio}"
						secret: "${ARCHIVE_SECRET_ACCESS_KEY:-minio123}"
					}
					max_in_flight: 1
					batching: {
						count:  product.archive.batchCount
						period: product.archive.batchPeriod
						processors: [{
							parquet_encode: {
								schema: [
									{name: "id",          type: "UTF8"},
									{name: "specversion", type: "UTF8"},
									{name: "type",        type: "UTF8"},
									{name: "source",      type: "UTF8"},
									{name: "time",        type: "TIMESTAMP"},
									{name: "subject",     type: "UTF8"},
									{name: "data",        type: "BYTE_ARRAY"},
								]
								default_compression:   "zstd"
								default_timestamp_unit: "MICROSECOND"
							}
						}]
					}
				}
			}

			metrics: {
				prometheus: {
					add_process_metrics: true
				}
			}
		}
	}
}

minioValues: {
  repository: url: "oci://registry-1.docker.io/bitnamicharts"
  chart: {
    name:    "minio"
    version: "14.7.0"
  }
	sync: {
		targetNamespace: runtime.welkinNamespace
		createNamespace: true
		timeout:         15
	}
  helmValues: {
    fullnameOverride: "minio"
    image: {
      registry:   "docker.io"
      repository: "bitnamilegacy/minio"
      tag:        "2025.7.23-debian-12-r3"
    }
    clientImage: {
      registry:   "docker.io"
      repository: "bitnamilegacy/minio-client"
      tag:        "2025.7.21-debian-12-r2"
    }
    // MinIO root creds come from the SOPS-encrypted `welkin-minio` Secret
    // (generated at build time), not inline.
    auth: {
      existingSecret: "welkin-minio"
    }
    defaultBuckets: runtime.archive.bucket
    mode:           "standalone"
  }
}

// Cilium — the cluster CNI and zero-trust dataplane.
// Installed FIRST (foundational): eBPF kube-proxy replacement, Hubble
// observability, WireGuard transparent encryption. Identity-aware policies
// (CiliumNetworkPolicy / CiliumClusterWideNetworkPolicy) enforce the
// "OpenMeter is enemy" boundary by Kubernetes service account / namespace,
// not pod IP.
ciliumValues: {
	repository: url: "oci://registry-1.docker.io/cilium/charts"
	chart: {
		name:    "cilium"
		version: product.charts.ciliumVersion
	}
	sync: {
		targetNamespace: "kube-system"
		createNamespace: true
		timeout:         15
	}
	helmValues: {
		// ponytail: kube-proxy replacement requires the chart's init to run
		// privileged; acceptable for a CNI. Single-replica operator is fine.
		kubeProxyReplacement: "true"
		operator: {replicas: 1}

		// Hubble — real-time flow observability (continuous verification of the
		// isolation boundary). Relay + UI for humans; Prometheus for metrics.
		hubble: {
			enabled:          true
			metrics: {enabled: {dns: true, drop: true, tcp: true, flow: true, icmp: true, http: true}}
			relay:   {enabled: true}
			ui:      {enabled: true}
		}

		// WireGuard transparent encryption between nodes.
		encryption: {
			enabled: true
			type:    "wireguard"
		}

		// L7 policy engine (Envoy) for Kafka-protocol filtering on shared brokers.
		enableEnvoyConfig: true

		ipam: {mode: "kubernetes"}
	}
}

// Kyverno — policy-as-code admission controller (YAML-native, no Rego).
// Enforces the "enemy" guardrails as reviewable, GitOps-synced policy:
//   - workload-scoped default-deny is enforced by Cilium
//   - force automountServiceAccountToken: false
//   - enforce Pod Security Standards (restricted-lite)
//   - block ClusterRoleBindings outside platform namespaces (no OpenMeter
//     escalation to read Welkin secrets)
//   - verify image signatures (cosign) — Audit first, then Enforce
kyvernoValues: {
	repository: url: "oci://registry-1.docker.io/kyverno/charts"
	chart: {
		name:    "kyverno"
		version: product.charts.kyvernoVersion
	}
	sync: {
		targetNamespace: "kyverno"
		createNamespace: true
		timeout:         15
	}
	helmValues: {
		replicaCount: 1
		// ponytail: one replica is enough for admission webhooks at this scale;
		// raise for HA admission throughput.
		reportsController: {enabled: true}
		backgroundController: {enabled: true}
		cleanupController: {enabled: true}
		admissionController: {timeoutSeconds: 5}
		resourceFilters: [
			// Don't police the CNI / platform control planes.
			"*[Pod/*/kube-system]",
			"*[Node/]",
			"*[Event/*/*]",
		]
	}
}

// Strimzi — Apache Kafka on Kubernetes, Welkin-owned. Hosts welkin_canonical
// (the canonical event bus). Portable: runs on any K8s; a cloud-locked
// deployment can swap in managed Kafka via the same KafkaTopic/KafkaUser CRs.
strimziValues: {
	repository: url: "oci://registry-1.docker.io/strimzi/charts"
	chart: {
		name:    "strimzi-kafka-operator"
		version: product.charts.strimziVersion
	}
	sync: {
		targetNamespace: runtime.welkinNamespace
		createNamespace: true
		timeout:         15
	}
	helmValues: {
		// ponytail: default watch namespaces = same as release ns (welkin-system).
		// The operator reconciles Kafka/KafkaTopic/KafkaUser in welkin-system.
		watchNamespaces: [runtime.welkinNamespace]
		image: {repository: "registry-1.docker.io/strimzi"}
	}
}

// Welkin platform bundle. Renders to Flux HelmReleases via the
// flux-helm-release Timoni module; CI pushes the rendered manifests + the
// policy/CR YAMLs under platform/infra as a cosign-signed OCI artifact that
// Flux reconciles (NO `timoni bundle apply`).
//
// Trust domains:
//   welkin-system    — collector, archive, minio, strimzi (Welkin-owned)
//   openmeter-system — openmeter, postgres (untrusted economic tenant)
//   kube-system      — cilium (CNI)
//   kyverno          — kyverno (policy)
//
// Install order: cilium (CNI) -> kyverno (policy) -> strimzi (kafka) ->
// postgres -> openmeter -> collector -> archive -> minio.

bundle: {
	apiVersion: "v1alpha1"
	name:       "welkin"
	instances: {
		cilium: {
			module: {
				url:     "oci://ghcr.io/stefanprodan/modules/flux-helm-release"
				version: product.charts.fluxModuleVersion
			}
			namespace: "kube-system"
			values:    ciliumValues
		}

		kyverno: {
			module: {
				url:     "oci://ghcr.io/stefanprodan/modules/flux-helm-release"
				version: product.charts.fluxModuleVersion
			}
			namespace: "kyverno"
			values:    kyvernoValues & {
				dependsOn: [{name: "cilium"}]
			}
		}

		strimzi: {
			module: {
				url:     "oci://ghcr.io/stefanprodan/modules/flux-helm-release"
				version: product.charts.fluxModuleVersion
			}
			namespace: runtime.welkinNamespace
			values:    strimziValues & {
				dependsOn: [{name: "cilium"}]
			}
		}

		postgres: {
			module: {
				url:     "oci://ghcr.io/stefanprodan/modules/flux-helm-release"
				version: product.charts.fluxModuleVersion
			}
			namespace: runtime.economicNamespace
			values:    postgresValues & {
				dependsOn: [{name: "cilium"}]
			}
		}

		openmeter: {
			module: {
				url:     "oci://ghcr.io/stefanprodan/modules/flux-helm-release"
				version: product.charts.fluxModuleVersion
			}
			namespace: runtime.economicNamespace
			values: openmeterValues & {
				dependsOn: [{name: "postgres"}]
			}
		}

		collector: {
			module: {
				url:     "oci://ghcr.io/stefanprodan/modules/flux-helm-release"
				version: product.charts.fluxModuleVersion
			}
			namespace: runtime.welkinNamespace
			values: collectorValues & {
				dependsOn: [{name: "openmeter"}, {name: "strimzi"}]
			}
		}

		archive: {
			module: {
				url:     "oci://ghcr.io/stefanprodan/modules/flux-helm-release"
				version: product.charts.fluxModuleVersion
			}
			namespace: runtime.welkinNamespace
			values: archiveValues & {
				dependsOn: [{name: "strimzi"}, {name: "minio"}]
			}
		}

		minio: {
			module: {
				url:     "oci://ghcr.io/stefanprodan/modules/flux-helm-release"
				version: product.charts.fluxModuleVersion
			}
			namespace: runtime.welkinNamespace
			values:    minioValues & {
				dependsOn: [{name: "cilium"}]
			}
		}
	}
}
