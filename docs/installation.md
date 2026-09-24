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

## ForemanRelease controller (experimental)

The guarded scripts remain the supported development entry point. The same
sequence is also implemented by the experimental `ForemanRelease` controller.
Its image contains only this orchestration repository, Ruby, Helm, and kubectl;
Foreman, Katello, Candlepin, Pulp, and Smart Proxy remain separate images and
Helm releases.

Publish `images/release-operator/Dockerfile` through the operator image workflow
and retain the digest it reports. Then install the chart; Helm creates the CRD
before the controller pair during the first installation:
in the application namespace:

```sh
kubectl create namespace foreman
helm upgrade --install foreman-release-operator \
  charts/foreman-release-operator \
  --namespace foreman \
  --set-string image.repository=ghcr.io/OWNER/REPOSITORY/release-operator \
  --set-string image.tag=VERSION@sha256:REVIEWED_DIGEST
```

Helm intentionally does not upgrade CRDs. Before upgrading an existing
operator release to a repository revision whose CRD changed, apply the reviewed
CRD explicitly and only then upgrade the chart:

```sh
kubectl apply --server-side \
  --field-manager=foreman-release-operator \
  --filename operator/crd/platform.theforeman.org_foremanreleases.yaml
```

Store the two environment value documents in one same-namespace Secret. They
may reference the normal runtime credential Secrets; their contents are not
copied into the custom resource or its status.

```sh
kubectl --namespace foreman create secret generic foreman-release-values \
  --from-file=application.yaml=/secure/path/application-values.yaml \
  --from-file=execution-proxy.yaml=/secure/path/execution-proxy-values.yaml
kubectl --namespace foreman apply --filename examples/foreman-release.yaml
kubectl --namespace foreman get foremanrelease foreman --watch
```

The operator Service exposes `/metrics` on port 9393 by default. Kubernetes
uses `/livez` for process liveness and `/readyz` for the freshness of successful
API cycles. Configure a Prometheus scraper through `service.annotations`, and
alert on `foreman_release_controller_ready == 0`, increasing failed cycles, or
an old `foreman_release_controller_last_success_timestamp_seconds`.
The leader also exports `foreman_release_status`, desired and observed
generation gauges, drift-audit health, and deletion state for each CR. Standby
and API-failed candidates clear that inventory instead of serving stale release
state.
The Service publishes NotReady Pod addresses deliberately so a monitoring
system can still scrape the failure state. If the Prometheus Operator CRD is
installed, `monitoring.prometheusRule.enabled=true` adds alerts for missing
metrics, no ready candidate, unhealthy leader cardinality, and failed cycles;
it also reports a Ready release whose latest drift audit failed. Optional
`monitoring.prometheusRule.labels` attach the labels selected by that
Prometheus installation.
Set `monitoring.grafanaDashboard.enabled=true` when a Grafana dashboard sidecar
already watches labelled ConfigMaps. The default
`monitoring.grafanaDashboard.labels` uses `grafana_dashboard: "1"`; replace it
with the deployment's discovery label when necessary. The chart supplies only
the dashboard and never installs Grafana.

Two candidates run by default. A short namespaced leader Lease allows only the
Pod whose UID is the current holder to list and reconcile releases; the standby
takes over only after that Lease expires or is explicitly released. A separate
operation Lease continues to serialize the actual release mutation with manual
install, upgrade, backup, and restore workflows. Every release operation is
restart-safe: its input fingerprints, phase, operation Lease holder, migration
Job names, submitted Helm revisions, and verified Helm revisions are durable.
If part of a submitted Deployment or registration-Job set disappears, the
controller reapplies the same release with migration Jobs suppressed. Change
`spec.retryToken` only after correcting a `Blocked` condition. Set
`spec.paused=true` to stop at the next safe phase boundary; it never terminates
an active migration or rollout.

While `Ready`, the controller checks for missing Helm-managed objects and
out-of-band Helm revisions every `spec.driftCheckSeconds` (60 seconds by
default). Missing stateless resources or a changed Helm revision start a
uniquely identified repair: the normal preflight, lock, rollout, registration,
and smoke gates run again, while schema migrations remain skipped. A missing
PVC instead enters `Blocked` and requires explicit storage recovery. The check
never adopts changed values Secret content; update `spec.reconcileToken` when
that change is intentional.

The values Secrets are deliberately not watched as implicit rollout triggers.
After changing their content, including a `secretRolloutToken` used for
credential rotation, change `spec.reconcileToken`. The controller then creates
a new operation, fingerprints and validates both current Secret payloads, and
runs the complete application-plus-execution release even when
`spec.compatibilitySet` is unchanged. `retryToken` has a separate purpose and
remains required to leave `Blocked`.

Completed controller-owned Job histories are retained for audit without a TTL,
then safely bounded after a successful release. Set `spec.operationHistoryLimit`
to keep between one and twenty completed operations (default: three). The
current operation and every operation with an unfinished Job are never pruned;
a cleanup failure leaves the release `Ready` and is retried by reconciliation.

Deleting a `ForemanRelease` is a detach operation, not an uninstall. Its
finalizer waits for the current migration or rollout to reach a safe pause,
releases the operation Lease, and then lets Kubernetes remove the CR while the
Foreman, execution-proxy, databases, PVCs, and external services remain in
place. Use the chart-specific uninstall and data-retention procedures only as
a separate, explicitly destructive operation.

Both `adoptExisting` flags default to false. Set the relevant flag only for the
first controlled takeover of an already installed Helm release, verify that
its values match the referenced Secret and compatibility profile, and return
the flag to false after ownership labels appear. A newly installed release or
one already labelled with this ForemanRelease UID needs no adoption override.

Before changing a failed deployment, capture the Secret-redacted, read-only
bundle described in [`diagnostics.md`](diagnostics.md). It preserves release,
Helm, workload, Job, Event, and cluster-capability evidence without requesting
Pod logs or Secret payloads.

This path has command-level and render coverage but no retained real-cluster
qualification yet. Do not replace the guarded scripts in production until the
full integration workflow has exercised the published operator image and exact
compatibility set.

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

It then applies only the Helm-adoptable migration dependencies and three
one-hour, operation-labelled migration Jobs. Application Deployments are not
submitted until all three Jobs complete. The installer applies the application
with migration rendering suppressed, waits for Pulp registration, runs the
application smoke test, installs the execution proxy, and waits for its Pod.
The final gate idempotently registers the proxy through Foreman's Rails model,
repeats the application smoke test, and then calls the execution proxy
`/features` endpoint through Service DNS with Foreman's client certificate.
The release is accepted only when Foreman associates the proxy with exactly
`Ansible`, `Dynflow`, and `Script`, server TLS and client trust match, and the
external endpoint returns the same exact feature boundary.

`RELEASE_LEASE_NAME`, `RELEASE_HOLDER_ID`, `RELEASE_OPERATION_ID`,
`RELEASE_LEASE_DURATION_SECONDS`, and
`RELEASE_LEASE_RENEW_INTERVAL_SECONDS` may override the Lease defaults. The
renew interval must remain shorter than the duration. A manually supplied
operation ID must be a fresh Kubernetes label value for each attempt; normally
the helper generates it.

The controller additionally bounds Preflight, Lease acquisition, migrations,
both workload rollouts, and verification through `spec.timeouts`. A phase that
exceeds its budget becomes `Blocked`; the operation Lease is released, but no
schema or workload rollback is attempted. Correct the scheduling, image,
storage, or endpoint failure and change `spec.retryToken` to reconcile again.
Every managed Deployment also has a shorter Kubernetes progress deadline, so
the controller can normally report the exact `ProgressDeadlineExceeded`
workload before the broader phase budget is exhausted.
Controller-side Helm and kubectl commands are independently bounded by
`controller.commandTimeoutSeconds`. A timed-out process group receives TERM
and then KILL after `controller.commandTerminationGraceSeconds`; the release
Lease is required to remain valid for more than four such command windows.

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
