# Foreman on Kubernetes

This repository composes separately released Foreman, Katello, Candlepin, and Pulp container images into a scalable Kubernetes deployment. It does not vendor or merge any of the application source trees.

## Component boundary

- **Foreman** remains its own source repository and image.
- **Katello** remains its own source repository and release, but runs as a Rails plugin inside the compatible Foreman image. It is therefore not modelled as a fake standalone Deployment.
- **Candlepin** remains its own Java service, image, configuration, and Deployment.
- **Pulp** remains its own service family. API, content, and worker processes scale independently.
- This repository owns only Kubernetes orchestration, upgrade sequencing, health contracts, and deployment policy.
- Smart Proxies remain independent edge or execution-plane services. The
  application chart never embeds DHCP, DNS, TFTP, or another generic proxy in
  the Foreman web pods.
- Kubernetes nodes require no Foreman or Katello packages, host services,
  runtime sockets, or application filesystem mounts. The current image set is
  Linux/amd64, but the node distribution is an integration-test dimension
  rather than an application packaging dependency.

The separate [`charts/foreman-execution-proxy`](charts/foreman-execution-proxy)
chart now models a central singleton executor for Remote Execution SSH and
Ansible. Its positive feature check explicitly excludes every provisioning and
network-control feature; see
[`docs/execution-proxy.md`](docs/execution-proxy.md) for its state, identity,
role-content, and network contracts.

The experimental [`charts/foreman-release-operator`](charts/foreman-release-operator)
chart installs two namespaced controller candidates with Lease-based leader
election for the durable
`ForemanRelease` state machine. It validates the exact render and external
dependencies, pins all input fingerprints, adopts deterministic migration and
verification Jobs after restart, runs an authenticated read-only dependency
gate before migrations, runs migrations before changing application
workloads, rolls the application before its paired
execution proxy, and never performs an automatic post-migration rollback.

The initial Helm chart is under [`charts/foreman-stack`](charts/foreman-stack). It renders:

- a scalable Foreman web Deployment;
- one Dynflow orchestrator and independently scalable worker Deployments;
- a Candlepin Deployment with an opt-in external-Artemis and clustered-Quartz HA mode;
- separate Pulp API, content, and worker Deployments backed by shared RWX or
  S3-compatible object storage;
- a private, mutually authenticated Pulp control endpoint and automatic registration of Pulp in Foreman;
- an optional ingress-nginx profile for Foreman and public Pulp content;
- independent optional HPAs for Foreman web, both Dynflow worker pools, Pulp
  API, and Pulp content replicas; the Dynflow orchestrator remains a singleton;
- separate Candlepin, Pulp, and Foreman migration Jobs;
- a guarded, operation-owned dependency Job that verifies all three databases,
  Foreman's and Pulp's Valkey endpoints, and Pulp S3 access before migrations;
- Foreman recurring tasks as non-overlapping CronJobs.
- maintenance-gated, encrypted backup and restore Jobs covering all three
  PostgreSQL databases, both releases' Secrets, Foreman avatars, execution
  state and Ansible content, plus Pulp filesystem content when that backend is
  selected, with an explicit external recovery gate for S3.
- explicit non-root identities, restricted container privileges, scoped
  disruption budgets, release-wide default-deny ingress, and optional
  component-level egress isolation.
- consistent node selectors, taint tolerations, and verified PriorityClasses
  across long-running workloads and release-gating Jobs.
- opt-in Prometheus Operator workload alerts for application and execution
  availability, crash loops, failed Jobs, and storage provisioning failures.

## Current status

This is an implementation scaffold, not yet a production release. It deliberately requires external PostgreSQL and Valkey services and pre-created Kubernetes Secrets. Those stateful dependencies need their own HA, backup, and lifecycle policy rather than being hidden inside an application chart. Production defaults require hostname-verified PostgreSQL and authenticated Valkey TLS; the disposable Kind profile is the only supplied profile that explicitly disables them. Cache, Dynflow, and Pulp can use separate Valkey endpoints so durable queues never have to inherit a cache eviction policy.

The chart generates the non-secret Foreman, Katello, Dynflow, Candlepin, Tomcat, Pulp, and internal NGINX configuration from typed values. Existing Secrets are limited to credentials, encryption material, and certificates. The Pulp administrative API is not published by the ingress profile; Katello reaches it through a private mTLS endpoint that only maps approved client-certificate common names to Pulp's remote `admin` user.

The default remains one Candlepin replica. More replicas require the explicit
HA contract: external Artemis, clustered JDBC Quartz, and chart-owned Liquibase
migrations. The Deployment still uses `Recreate`, so runtime pod failure is
covered but zero-downtime schema upgrades are not yet claimed.

## Render the chart

```sh
helm lint charts/foreman-stack
helm template foreman charts/foreman-stack \
  --values examples/cluster-values.yaml

helm lint charts/foreman-execution-proxy \
  --values examples/execution-proxy-values.yaml

helm lint charts/foreman-release-operator
```

After an installed release is ready, run the chart-owned application smoke
test. It checks the Foreman/Katello aggregate health endpoint and the Candlepin
and Pulp service health endpoints from inside the same NetworkPolicy boundary:

```sh
helm test foreman --namespace foreman --logs
```

The execution plane is opt-in on both sides: add
[`examples/execution-control-plane-values.yaml`](examples/execution-control-plane-values.yaml)
to the `foreman-stack` release and deploy the separate proxy values alongside
it. This keeps Remote Execution and Ansible out of the default application
profile until their real integration drill passes.

The Candlepin HA contract is available as a separate overlay in
[`examples/candlepin-ha-values.yaml`](examples/candlepin-ha-values.yaml); it
requires an operator-supplied external Artemis service and Secrets.

Pulp can replace its shared RWX claim with S3-compatible object storage through
[`examples/pulp-s3-values.yaml`](examples/pulp-s3-values.yaml). The complete
credential, egress, direct-download, and recovery contract is documented in
[`docs/pulp-object-storage.md`](docs/pulp-object-storage.md).

The example Secrets contain placeholders only. Populate them outside Git. For
a paired, digest-pinned installation, create the namespace and Secrets, prepare
separate application and execution-proxy values files, then use the guarded
installer (the current default set is still a candidate):

```sh
kubectl create namespace foreman
kubectl apply --namespace foreman --filename /secure/path/foreman-secrets.yaml
ALLOW_CANDIDATE=1 scripts/install-release.sh \
  /secure/path/application-values.yaml \
  /secure/path/execution-proxy-values.yaml
```

The installer rejects existing releases, applies environment values before the
digest-pinned profiles, waits for schema Jobs, requires the application smoke
test, and only then installs the paired execution proxy. Existing deployments
must use the controlled upgrade helper instead.

Static render checks are available as `tests/render.sh` and run in the lightweight pull-request workflow together with ShellCheck. The opt-in disposable integration harness under `tests/kind/` exercises a real install, the chart-owned application smoke test, mTLS Pulp registration, successful, failed, cancelled, and proxy-interrupted Remote Execution jobs, Ansible command execution, role discovery/import/assignment/execution through the egress-restricted central proxy, replacement of already imported role content, Foreman Webhooks delivery, the Foreman-side virt-who configuration and recovery lifecycle, an explicit denied-destination probe, clean-namespace disaster recovery, full proxy TLS/client/SSH identity rotation, a failed migration with retained old workloads and roll-forward recovery, release-controller leader takeover, stateless and stateful drift handling, validated external-Secret rotation, certificate-expiry observation, scaling, and controlled application and proxy upgrades while jobs are active. It cleans up the generated cluster and PKI by default and is not run for every change. A manual `Full integration` workflow provides the intended amd64 execution environment.

Application and execution-proxy image profiles are paired in
`compatibility/release-sets.json`. Declared sets are digest-pinned and remain
`candidate` until the complete runtime drill passes for that exact combination.
The independent `compatibility/cluster-platforms.json` registry binds that
qualification to an exact Kubernetes node image, container runtime, ingress
chart, Pod Security version, and native runner architecture. A different node
image remains useful for diagnostics but cannot promote a release set under
another platform's identity.
Successful full runs emit retained, input-hashed evidence; promotion remains an
explicit reviewed change and rejects local, partial, or stale results.
The guarded two-release upgrade sequence is implemented in
[`scripts/upgrade-release.sh`](scripts/upgrade-release.sh) and documented in
[`docs/upgrades.md`](docs/upgrades.md); it intentionally never rolls back an
already migrated database automatically.

The recovery Jobs are intentionally one-shot rather than scheduled online
backups. They enter through an explicit maintenance revision, verify that all
writers have stopped, and use an independently managed Restic repository. The
guarded recovery helper serializes them with installs/upgrades, preserves the
digest-pinned release set, can bootstrap both maintenance releases in a clean
namespace, and resumes normal workloads only after success. See
[`docs/disaster-recovery.md`](docs/disaster-recovery.md) for the backup, restore,
credential, and recovery-drill contracts.

## Design documents

- [`docs/architecture.md`](docs/architecture.md) describes ownership and topology.
- [`docs/installation.md`](docs/installation.md) defines prerequisites, guarded first installation, and failure handling.
- [`docs/runtime-contracts.md`](docs/runtime-contracts.md) records the verified upstream runtime contracts and current scaling limits.
- [`docs/upstream-runtime-readiness.md`](docs/upstream-runtime-readiness.md) tracks application changes that must ship upstream before a release set can be supported.
- [`docs/local-candidate-images.md`](docs/local-candidate-images.md) builds those exact unpublished commits into non-publishable amd64 images for integration testing without maintaining application forks.
- [`docs/capacity-planning.md`](docs/capacity-planning.md) turns replica,
  process, thread, and database-pool settings into external service sizing
  bounds.
- [`docs/compatibility.md`](docs/compatibility.md) records digest-pinned image candidates and their test status.
- [`docs/upgrades.md`](docs/upgrades.md) defines preflight, two-release sequencing, failure states, and the schema rollback boundary.
- [`docs/plugin-compatibility.md`](docs/plugin-compatibility.md) records the packaged plugin inventory, proof level, and Smart Proxy placement policy.
- [`docs/execution-proxy.md`](docs/execution-proxy.md) defines the restricted Kubernetes Remote Execution and Ansible proxy profile.
- [`docs/disaster-recovery.md`](docs/disaster-recovery.md) defines portable recovery sets and the destructive restore gate.
- [`docs/diagnostics.md`](docs/diagnostics.md) defines the read-only, Secret-redacted support bundle.
- [`docs/candlepin-ha.md`](docs/candlepin-ha.md) defines the external broker, clustered scheduler, and migration boundary.
- [`docs/pulp-object-storage.md`](docs/pulp-object-storage.md) defines the optional S3-compatible artifact backend and its recovery boundary.
- [`docs/kubevirt.md`](docs/kubevirt.md) defines KubeVirt compatibility gates, least-privilege provider RBAC, safe token rotation, egress, and external qualification.
- [`docs/roadmap.md`](docs/roadmap.md) lists the next implementation slices.
- [`operator/README.md`](operator/README.md) defines the controller API, phase ownership, and failure/retry contract.

## Upstream source snapshots reviewed

The sibling `foreman-kubernetes-upstream/` directory is intentionally not part
of this Git repository. It contains independent upstream working clones. Any
reusable application or image behavior is implemented and tested there for
submission to its owning project; this repository consumes only published
upstream contracts and keeps Kubernetes-specific orchestration here. The
machine-readable state of prepared and published contracts lives in
`compatibility/upstream-contracts.json`.

| Project | Branch | Commit |
| --- | --- | --- |
| Foreman | `develop` | `a21273a13820103c2f569a4d5446806dfff3dae0` |
| Katello | `master` | `a4a5ed2d72932c967bdf0e9c8c82b3e75bad9b5a` |
| Candlepin | `main` | `0928757731c4f5537207c860803fca2fbc7044f5` |
| Foreman Remote Execution | `master` | `be391fd9ef3140df707eed4f320ce2ebd572648d` |
| Foreman Ansible | `master` | `7ffc9e37344011554347ca9429fffdcf1f81816e` |
| Foreman Webhooks | `master` | `4ad5882f4b866cb55b0d1bb102010ddb1e448ebd` |
| Foreman virt-who Configure | `master` | `78b9e78650013b6ef023a4163a7d47518024cd1d` |
| Foreman KubeVirt (reviewed upstream) | `master` | `4b89174424245289bd4cc7535a94a8c24aa19172` |
| Fog KubeVirt (reviewed upstream) | `master` | `d3277fa121609c5a2c949f3518f5f1bb07ef6447` |
| foremanctl | `master` | `cb135b25817fba875061a7d4495fe14ad2bd474e` |
| Smart Proxy | `develop` | `c2af3d35497058fd7dc8146dcbca3adf60334b9e` |
| Smart Proxy Dynflow | `master` | `a07e3fa37aca20f2038e8f469f88c545c39276ff` |
| Smart Proxy Remote Execution SSH | `master` | `1ad66baae4498f7f3a5e3cc939ddf20e188336d2` |
| Smart Proxy Ansible | `master` | `080753705e26a6a9aaa68a413a6935c9ac48c8ad` |

OCI image repositories for Foreman, Candlepin, and Pulp were reviewed separately as well.

The table records reviewed upstream bases. Local upstream branches are tracked
separately in `compatibility/upstream-contracts.json`; their commits are not a
claim that an official image already contains the change.
