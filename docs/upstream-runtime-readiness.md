# Upstream runtime readiness

This repository owns Kubernetes orchestration, not private application forks.
When the chart needs a reusable runtime capability, the implementation belongs
to the relevant upstream and must preserve its normal standalone defaults.
[`compatibility/upstream-contracts.json`](../compatibility/upstream-contracts.json)
records those changes and the release sets that actually contain them.

There are three distinct states:

- `local-upstream-commit`: implemented and checked in an independent upstream
  working clone, but not merged or published;
- `merged-upstream`: accepted upstream, but not yet present in a referenced
  image release;
- `published`: present in the exact release sets listed by the contract.

A successful Helm render proves only the orchestration contract. A release set
cannot become `supported` until every contract required by its selected
profiles is `published` and names that release set. The current nightly set is
therefore deliberately still a candidate.

## Default deployment

| Contract | Upstream behavior | Kubernetes use |
| --- | --- | --- |
| `foreman-configurable-puma-run-dir` | Adds an opt-in `FOREMAN_RUN_DIR`; the default remains `Rails.root/tmp`. | Places Puma runtime files on a bounded writable runtime volume. |
| `foreman-dynflow-readiness-file` | Adds opt-in lifecycle signaling through `DYNFLOW_READINESS_FILE`. | Makes readiness follow the real Dynflow process lifecycle without injected Ruby code. |
| `foreman-escaped-client-certificate` | Accepts ingress-nginx's URL-escaped PEM form while retaining existing PEM and DER inputs. | Authenticates a verified client certificate forwarded by ingress-nginx. |
| `foreman-dynflow-redis-tls-ca` | Adds opt-in CA verification through `DYNFLOW_REDIS_SSL_CA_FILE`. | Verifies the external Dynflow Redis/Valkey endpoint without replacing the initializer. |
| `katello-pulp-non-default-port` | Preserves an explicit non-default port in generated Pulp clients. | Reaches the private Pulp control proxy on its declared Service port. |
| `katello-event-daemon-foreground` | Adds a foreground runner, configurable tmp directory, and heartbeat while retaining the existing daemon entry point. | Runs one supervised event-daemon process as container PID 1. |
| `candlepin-container-runtime` | Keeps the packaged Tomcat server as the default command and adds a numeric image user plus a migration entry point. | Runs Candlepin as non-root and invokes Liquibase in a bounded migration Job. |

## Optional Pulp object storage

| Contract | Upstream behavior | Kubernetes use |
| --- | --- | --- |
| `pulpcore-el10-botocore-dateutil-epoch` | Corrects the EL10 botocore dependency without changing other package targets. | Allows the object-storage dependencies to resolve in the official image build. |
| `pulpcore-package-django-storages` | Publishes `django-storages` without selecting it automatically. | Supplies Pulpcore's supported S3 storage backend. |
| `pulp-image-object-storage-runtime` | Includes boto3 and django-storages; filesystem storage remains the default. | Enables the chart's opt-in S3-compatible storage profile. |

## Optional KubeVirt provider

| Contract | Upstream behavior | Kubernetes use |
| --- | --- | --- |
| `foreman-kubevirt-provider-correctness` | Improves API discovery, validation, credential guidance, and safe PVC lifecycle in the provider. | Enables the optional Foreman compute resource without broad cluster credentials or destructive failure ordering. |
| `fog-kubevirt-namespaced-resources` | Scopes network discovery and creates VMs with the grouped discovered API version. | Keeps provider RBAC namespace-bound and compatible with current KubeVirt APIs. |

The local branches and commit hashes are development evidence, not release
provenance. Once a change is merged and an official image is published, update
the contract state and `availableInReleaseSets` only after verifying that exact
digest contains the capability.
