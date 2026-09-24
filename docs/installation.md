# Installation

The platform is installed as a paired application and execution-proxy release.
The pair must come from one entry in `compatibility/release-sets.json`; do not
mix image profiles from different sets.

## Prerequisites

- a Kubernetes cluster with a default StorageClass and an ingress controller;
- external PostgreSQL databases for Foreman, Candlepin, and Pulp;
- external Valkey/Redis endpoints for Rails caching, Dynflow, and Pulp; the
  production profile requires authenticated TLS and a trusted CA;
- DNS names and TLS material for the Foreman and Pulp endpoints;
- the namespace and every Secret referenced by the selected values;
- Helm, kubectl, jq, Ruby, and access to the digest-pinned images.
- permission to create, read, update, and delete a namespaced Kubernetes Lease;
- When ingress is enabled, an IngressClass backed by
  `k8s.io/ingress-nginx`; the install and upgrade helpers verify the
  controller because the client-certificate bridge uses ingress-nginx
  variables and annotations.
- When a resource-based horizontal autoscaler is enabled, the aggregated
  `v1beta1.metrics.k8s.io` API must exist and report `Available=True` (normally
  provided by metrics-server).

The chart does not create production credentials. Copy the example values into
deployment-owned files outside this repository and create the referenced
Secrets through the site's secret-management workflow.

The three Valkey endpoint blocks may reference one service, but a production
deployment should keep the disposable Foreman cache separate from the durable
Dynflow queue. Configure the Dynflow service with persistence, replication or
managed failover, and `maxmemory-policy noeviction`. The Foreman cache and
Dynflow `*-uri-auth` Secret values are URI userinfo including the trailing
`@`; percent-encode reserved characters before storing them. Pulp uses the
separate raw `pulp-password` value for its default Valkey ACL user.

Foreman email is opt-in. Set `foreman.email.enabled=true`, configure the relay
under `foreman.email.smtp`, and create the selected two-key Secret when SMTP
authentication is used. The chart enables automatic STARTTLS and certificate
peer verification; use a relay with a certificate trusted by the Foreman
image. When egress isolation is enabled, declare only that relay and its actual
port under `networkPolicy.egress.external.smtp`.

## Guarded first installation

Create the namespace and Secrets first:

```sh
kubectl create namespace foreman
kubectl apply --namespace foreman --filename /secure/path/foreman-secrets.yaml
```

Then install the paired release set:

```sh
ALLOW_CANDIDATE=1 scripts/install-release.sh \
  /secure/path/application-values.yaml \
  /secure/path/execution-proxy-values.yaml
```

`ALLOW_CANDIDATE=1` is required only while the selected set has not completed
the retained amd64 integration qualification. Do not use it as a substitute
for that qualification on a production cluster.

The installer performs these gates before changing application resources:

1. it resolves the requested compatibility set and rejects retired or
   unapproved candidate sets;
2. it acquires the same renewable release Lease used by upgrades, so two
   install/upgrade helpers cannot race each other; a crashed holder becomes
   reclaimable after the Lease expires;
3. it refuses to overwrite an existing Helm release;
4. it renders and lints both charts with deployment values followed by the
   authoritative digest-pinned image profiles;
5. it verifies every referenced IngressClass, named or default StorageClass,
   required resource Metrics API, external PVC, and external ServiceAccount;
6. it discovers every non-optional, externally managed Secret used by a Pod
   template and verifies both the Secret and each explicitly referenced key;
7. it rejects maintenance-only renders that omit normal migration workloads.

It then waits for application migrations and Pulp registration, runs the
application smoke test, installs the execution proxy, waits for its Pod, and
runs the application smoke test once more.

`RELEASE_LEASE_NAME`, `RELEASE_HOLDER_ID`,
`RELEASE_LEASE_DURATION_SECONDS`, and
`RELEASE_LEASE_RENEW_INTERVAL_SECONDS` may override the Lease defaults. The
renew interval must remain shorter than the duration.

## Failure boundary

The script intentionally does not use Helm's atomic rollback. A failed install
may already have advanced one or more database schemas, and rolling workload
manifests back cannot roll those schemas back safely. Inspect the failed Jobs
and release state, repair the cause, and retry the same compatibility set.

If the application smoke gate fails, the execution proxy is not installed. If
the proxy fails after the application succeeded, keep the application release
and repair or retry only the proxy side. Never delete production PVCs or
databases as part of an automated retry.

Existing releases must use `scripts/upgrade-release.sh` and the procedure in
[`upgrades.md`](upgrades.md).
