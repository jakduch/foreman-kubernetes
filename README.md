# Foreman on Kubernetes

This repository composes separately released Foreman, Katello, Candlepin, and Pulp container images into a scalable Kubernetes deployment. It does not vendor or merge any of the application source trees.

## Component boundary

- **Foreman** remains its own source repository and image.
- **Katello** remains its own source repository and release, but runs as a Rails plugin inside the compatible Foreman image. It is therefore not modelled as a fake standalone Deployment.
- **Candlepin** remains its own Java service, image, configuration, and Deployment.
- **Pulp** remains its own service family. API, content, and worker processes scale independently.
- This repository owns only Kubernetes orchestration, upgrade sequencing, health contracts, and deployment policy.

The initial Helm chart is under [`charts/foreman-stack`](charts/foreman-stack). It renders:

- a scalable Foreman web Deployment;
- one Dynflow orchestrator and independently scalable worker Deployments;
- a single-replica Candlepin Deployment with its native status probe;
- separate Pulp API, content, and worker Deployments backed by shared RWX storage;
- a private, mutually authenticated Pulp control endpoint and automatic registration of Pulp in Foreman;
- an optional ingress-nginx profile for Foreman and public Pulp content;
- independent optional HPAs for Foreman web, Pulp API, and Pulp content replicas;
- ordered Pulp and Foreman migration Jobs;
- Foreman recurring tasks as non-overlapping CronJobs.

## Current status

This is an implementation scaffold, not yet a production release. It deliberately requires external PostgreSQL and Valkey services and pre-created Kubernetes Secrets. Those stateful dependencies need their own HA, backup, and lifecycle policy rather than being hidden inside an application chart.

The chart generates the non-secret Foreman, Katello, Dynflow, Candlepin, Tomcat, Pulp, and internal NGINX configuration from typed values. Existing Secrets are limited to credentials, encryption material, and certificates. The Pulp administrative API is not published by the ingress profile; Katello reaches it through a private mTLS endpoint that only maps approved client-certificate common names to Pulp's remote `admin` user.

The chart currently prevents more than one Candlepin replica. The current Candlepin defaults use an embedded Artemis broker, and its Quartz configuration is not clustered. Scaling that Deployment before both concerns are addressed would create isolated queues and competing schedulers.

## Render the chart

```sh
helm lint charts/foreman-stack
helm template foreman charts/foreman-stack \
  --values examples/cluster-values.yaml
```

The example Secrets contain placeholders only. Populate them outside Git before installing:

```sh
kubectl apply --namespace foreman --filename /secure/path/foreman-secrets.yaml
helm upgrade --install foreman charts/foreman-stack \
  --namespace foreman \
  --create-namespace \
  --values examples/cluster-values.yaml
```

Static render checks are available as `tests/render.sh`. The opt-in disposable integration harness under `tests/kind/` exercises a real install, mTLS Pulp registration, scaling, and a second Helm revision. It cleans up the generated cluster and PKI by default and is not run as part of the lightweight local check.

## Design documents

- [`docs/architecture.md`](docs/architecture.md) describes ownership and topology.
- [`docs/runtime-contracts.md`](docs/runtime-contracts.md) records the verified upstream runtime contracts and current scaling limits.
- [`docs/compatibility.md`](docs/compatibility.md) records digest-pinned image candidates and their test status.
- [`docs/roadmap.md`](docs/roadmap.md) lists the next implementation slices.

## Upstream source snapshots reviewed

The sibling `foreman-kubernetes-upstream/` directory is intentionally not part of this Git repository. It contains independent, read-only working clones used for the initial analysis.

| Project | Branch | Commit |
| --- | --- | --- |
| Foreman | `develop` | `a21273a13820103c2f569a4d5446806dfff3dae0` |
| Katello | `master` | `49d8fcec35751d7e78a85cda5a0667239d17dcc9` |
| Candlepin | `main` | `0928757731c4f5537207c860803fca2fbc7044f5` |
| foremanctl | `master` | `cb135b25817fba875061a7d4495fe14ad2bd474e` |

OCI image repositories for Foreman, Candlepin, and Pulp were reviewed separately as well.
