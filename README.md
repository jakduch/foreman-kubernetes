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

The separate [`charts/foreman-execution-proxy`](charts/foreman-execution-proxy)
chart now models a central singleton executor for Remote Execution SSH and
Ansible. Its positive feature check explicitly excludes every provisioning and
network-control feature; see
[`docs/execution-proxy.md`](docs/execution-proxy.md) for its state, identity,
role-content, and network contracts.

The initial Helm chart is under [`charts/foreman-stack`](charts/foreman-stack). It renders:

- a scalable Foreman web Deployment;
- one Dynflow orchestrator and independently scalable worker Deployments;
- a Candlepin Deployment with an opt-in external-Artemis and clustered-Quartz HA mode;
- separate Pulp API, content, and worker Deployments backed by shared RWX or
  S3-compatible object storage;
- a private, mutually authenticated Pulp control endpoint and automatic registration of Pulp in Foreman;
- an optional ingress-nginx profile for Foreman and public Pulp content;
- independent optional HPAs for Foreman web, Pulp API, and Pulp content replicas;
- separate Candlepin, Pulp, and Foreman migration Jobs;
- Foreman recurring tasks as non-overlapping CronJobs.
- maintenance-gated, encrypted backup and restore Jobs covering all three
  PostgreSQL databases, application Secrets, and Pulp filesystem content when
  that backend is selected, with an explicit external recovery gate for S3.
- explicit non-root identities, restricted container privileges, scoped
  disruption budgets, and optional component-level egress isolation.

## Current status

This is an implementation scaffold, not yet a production release. It deliberately requires external PostgreSQL and Valkey services and pre-created Kubernetes Secrets. Those stateful dependencies need their own HA, backup, and lifecycle policy rather than being hidden inside an application chart.

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

The example Secrets contain placeholders only. Populate them outside Git before installing:

```sh
kubectl apply --namespace foreman --filename /secure/path/foreman-secrets.yaml
helm upgrade --install foreman charts/foreman-stack \
  --namespace foreman \
  --create-namespace \
  --values examples/cluster-values.yaml
```

Static render checks are available as `tests/render.sh` and run in the lightweight pull-request workflow together with ShellCheck. The opt-in disposable integration harness under `tests/kind/` exercises a real install, the chart-owned application smoke test, mTLS Pulp registration, successful, failed, cancelled, and proxy-interrupted Remote Execution jobs, Ansible command execution, role discovery/import/assignment/execution through the egress-restricted central proxy, replacement of already imported role content, an explicit denied-destination probe, clean-namespace disaster recovery, full proxy TLS/client/SSH identity rotation, a failed migration with retained old workloads and roll-forward recovery, scaling, and controlled application and proxy upgrades while jobs are active. It cleans up the generated cluster and PKI by default and is not run for every change. A manual `Full integration` workflow provides the intended amd64 execution environment.

Application and execution-proxy image profiles are paired in
`compatibility/release-sets.json`. Declared sets are digest-pinned and remain
`candidate` until the complete runtime drill passes for that exact combination.
Successful full runs emit retained, input-hashed evidence; promotion remains an
explicit reviewed change and rejects local, partial, or stale results.
The guarded two-release upgrade sequence is implemented in
[`scripts/upgrade-release.sh`](scripts/upgrade-release.sh) and documented in
[`docs/upgrades.md`](docs/upgrades.md); it intentionally never rolls back an
already migrated database automatically.

The recovery Jobs are intentionally one-shot rather than scheduled online
backups. They enter through an explicit maintenance revision, verify that all
writers have stopped, and use an independently managed Restic repository. See
[`docs/disaster-recovery.md`](docs/disaster-recovery.md) for the backup, restore,
credential, and recovery-drill contracts.

## Design documents

- [`docs/architecture.md`](docs/architecture.md) describes ownership and topology.
- [`docs/runtime-contracts.md`](docs/runtime-contracts.md) records the verified upstream runtime contracts and current scaling limits.
- [`docs/compatibility.md`](docs/compatibility.md) records digest-pinned image candidates and their test status.
- [`docs/upgrades.md`](docs/upgrades.md) defines preflight, two-release sequencing, failure states, and the schema rollback boundary.
- [`docs/plugin-compatibility.md`](docs/plugin-compatibility.md) records the packaged plugin inventory, proof level, and Smart Proxy placement policy.
- [`docs/execution-proxy.md`](docs/execution-proxy.md) defines the restricted Kubernetes Remote Execution and Ansible proxy profile.
- [`docs/disaster-recovery.md`](docs/disaster-recovery.md) defines portable recovery sets and the destructive restore gate.
- [`docs/candlepin-ha.md`](docs/candlepin-ha.md) defines the external broker, clustered scheduler, and migration boundary.
- [`docs/pulp-object-storage.md`](docs/pulp-object-storage.md) defines the optional S3-compatible artifact backend and its recovery boundary.
- [`docs/roadmap.md`](docs/roadmap.md) lists the next implementation slices.
- [`operator/README.md`](operator/README.md) defines the future controller API, phase ownership, and failure/retry contract.

## Upstream source snapshots reviewed

The sibling `foreman-kubernetes-upstream/` directory is intentionally not part of this Git repository. It contains independent, read-only working clones used for the initial analysis.

| Project | Branch | Commit |
| --- | --- | --- |
| Foreman | `develop` | `a21273a13820103c2f569a4d5446806dfff3dae0` |
| Katello | `master` | `49d8fcec35751d7e78a85cda5a0667239d17dcc9` |
| Candlepin | `main` | `0928757731c4f5537207c860803fca2fbc7044f5` |
| Foreman Remote Execution | `master` | `be391fd9ef3140df707eed4f320ce2ebd572648d` |
| Foreman Ansible | `master` | `7ffc9e37344011554347ca9429fffdcf1f81816e` |
| foremanctl | `master` | `cb135b25817fba875061a7d4495fe14ad2bd474e` |
| Smart Proxy | `develop` | `c2af3d35497058fd7dc8146dcbca3adf60334b9e` |
| Smart Proxy Dynflow | `master` | `a07e3fa37aca20f2038e8f469f88c545c39276ff` |
| Smart Proxy Remote Execution SSH | `master` | `1ad66baae4498f7f3a5e3cc939ddf20e188336d2` |
| Smart Proxy Ansible | `master` | `080753705e26a6a9aaa68a413a6935c9ac48c8ad` |

OCI image repositories for Foreman, Candlepin, and Pulp were reviewed separately as well.
