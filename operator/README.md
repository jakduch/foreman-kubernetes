# Foreman release operator contract

This directory defines the API and deterministic lifecycle contract for the
release controller. `operator/lib/foreman_release/state_machine.rb` is the
executable, side-effect-free transition core used to build durable status,
conditions, operation identity, explicit retries, and pause observations.
`operator/bin/foreman-release-controller` runs that core as a namespaced
polling controller and isolates failures between custom resources. The chart
installs the exact CRD from `operator/crd/` through its Helm `crds/` directory and
tests both copies byte-for-byte to prevent API drift. The chart
runs two candidates behind a PodDisruptionBudget. Each polling cycle renews a
separate leader Lease keyed by the Pod UID; a live foreign holder remains a
standby and an expired holder is replaced with a resource-version-guarded
update. The release-operation Lease below remains a second fence shared with
manual writers.

The controller serves `/livez`, `/readyz`, and Prometheus text metrics on its
health port. Readiness requires at least one successful leader or standby API
cycle within the configured staleness window; a responsive process with a
wedged or unreachable Kubernetes API therefore leaves Service endpoints
without triggering an immediate liveness restart. Metrics expose only process
state, current leader role, cycle counters, and the last successful timestamp,
plus each observed release phase and generation convergence. Metric labels are
limited to namespace, release name, and the fixed phase vocabulary; they never
contain release specs, Secret contents, or command output.
The metrics Service keeps NotReady candidates discoverable. An opt-in
`PrometheusRule` packages alerts only when its external CRD is explicitly
available; the operator chart does not install or own a monitoring stack.
The same opt-in rule group alerts on a `Blocked` release and on a generation
that remains unobserved for ten minutes. An independent opt-in Grafana
dashboard ConfigMap visualizes controller health, cycle outcomes, release
phases, blocked releases, and generation convergence. Its discovery labels are
configurable and the chart still does not install Grafana or a sidecar.
Every persisted phase transition and pause/resume condition also emits a
namespaced `events.k8s.io/v1` Event, so `kubectl describe` exposes release
progress without reading controller logs. Status remains authoritative: Event
publication is best-effort and an unavailable Event API cannot block or repeat
a release operation.

`operator/lib/foreman_release/reconciler.rb` turns the transition contract into
an idempotent reconciliation loop behind a side-effect adapter. It persists a
phase before the following reconciliation performs work, observes active
migrations and rollouts to a safe pause boundary, reuses the persisted
operation ID after restart, and accepts a blocked retry only after
`spec.retryToken` changes. A changed `spec.reconcileToken` starts the same full
validation and rollout for updated values or rotated Secrets without inventing
a new compatibility set. The Helm chart carries that ID plus the owning
ForemanRelease UID on deterministic migration and Pulp registration Jobs, so a
restarted controller adopts them rather than launching duplicate schema
changes.
Pending migration names and successfully submitted application/proxy Helm
revisions are checkpointed into the active operation before the next poll. A
missing member of an already submitted Deployment or registration-Job set
causes the controller to idempotently resubmit that release with migration Jobs
suppressed, instead of waiting until the phase timeout. This repairs partial
resource deletion without re-running a schema change.

The adapter boundary now includes three concrete, tested primitives:

- `ReleaseCatalog` resolves only in-image profiles, enforces candidate and
  retired-set policy, verifies profile identity, and rejects mutable image
  references;
- `ValuesReader` loads application and execution-proxy values only from the
  referenced Secret keys in the ForemanRelease namespace and requires each to
  be a YAML mapping;
- `KubernetesClient` lists namespaced releases, reads Secret keys without
  placing their contents in command arguments, and updates the status
  subresource with a JSON Patch `resourceVersion` precondition.

`RuntimeAdapter` binds those primitives to Helm and Kubernetes without a
blocking `--wait`. Validation pins SHA-256 fingerprints for both values Secret
keys and both in-image profiles into the operation status, so a mutable Secret
or a controller-image change cannot silently alter an in-flight release. It
prepares the chart-owned ServiceAccount, PVC, and desired ConfigMaps, then
creates three ForemanRelease-owned migration Jobs without changing any
Deployment. Existing Pods mount those ConfigMaps through `subPath`, so they
retain their old configuration inode during migrations. Only after all three
Jobs succeed does it submit the application Helm revision with migration Jobs
suppressed, observe every expected Deployment and Pulp registration Job, then
submit deterministic smoke-test Jobs. The execution-proxy release follows
the same operation identity and is applied only after the application smoke
test succeeds. Once available, an idempotent Rails Job registers it without an
API password and requires Foreman to associate exactly Ansible, Dynflow, and
Script before the final application and external mTLS smoke gates run.

Before the Lease is acquired, `ClusterPreflight` derives dependencies from the
exact combined render. It verifies referenced Secret keys, external PVCs and
ServiceAccounts, explicit or default StorageClasses, the required IngressClass
controller, and metrics API availability. The manual install and upgrade
scripts use the same `ManifestRequirements` implementation, so their preflight
inventory cannot drift from the controller.
The chart's namespaced Role is checked against every resource kind rendered by
both managed charts. A new application object cannot enter the release graph
without explicit CRUD coverage, while Pods remain read-only and cluster-scoped
preflight access remains separately read-only.

Operator-owned Jobs intentionally have no completion TTL, so Kubernetes cannot
erase an unobserved result during a controller outage. Once a release reaches
`Ready`, the controller removes only wholly terminal histories older than the
newest `spec.operationHistoryLimit` operations (three by default). It always
preserves the current operation and any operation containing an unfinished Job.
Cleanup is best-effort and cannot turn a healthy release into `Blocked`. Jobs
from the manual Helm workflow retain their one-hour TTL.

`LeaseManager` implements both fencing boundaries. Controller candidates use
the short-lived `foreman-release-controller-leader` Lease to elect one active
poller. Every release operation and all guarded shell workflows use the separate namespaced
`foreman-kubernetes-release` Lease. Its holder identity combines the durable
operation ID with the controller Pod UID, so a restarted
process in the same Pod can renew it while a replacement Pod must wait for the
old holder to release or expire. Another live holder causes a requeue, and only
an expired or explicitly released Lease can be claimed. Release is an
optimistic `replace` that clears the holder instead
of an unsafe unchecked delete. Every migration, rollout, and verification
reconciliation renews the Lease, including a release paused at a safe boundary.
Every Helm and kubectl subprocess has a hard execution deadline and runs in its
own process group. A timeout sends TERM and then KILL after a short grace
period, so a wedged client cannot bypass the CR phase budget or retain a Lease
forever. The operation Lease duration must exceed four command deadlines.
Preflight also rejects another ForemanRelease that names either of the same
Helm releases, preventing two CRs from taking turns mutating one release.
An existing Helm release without this CR's owner UID is rejected unless the
matching `spec.application.adoptExisting` or
`spec.executionProxy.adoptExisting` flag is explicitly enabled. Once labelled
resources exist, retries and later compatibility-set changes recognize the
release as already owned without keeping that adoption escape hatch enabled.

Every active phase has an explicit wall-clock budget in `spec.timeouts`.
`status.phaseStartedAt` survives controller restarts and Lease contention does
not reset it, so an unschedulable Pod or permanently pending rollout eventually
enters `Blocked` with the expired phase and budget recorded in operation
status. A pause at a safe boundary stops work; resuming intentionally starts a
fresh budget for that phase. Active migrations and rollouts continue to be
observed while paused and remain subject to their original safety deadline.

`ForemanRelease` is namespaced because its Helm releases, values Secrets,
migration Jobs, and status all belong to one application namespace. The
controller reads, but does not copy, the repository's digest-pinned
compatibility sets. Both the application and execution-proxy values are
referenced from same-namespace Secrets so credentials never enter the custom
resource or its status.

The controller owns release sequencing only:

1. validate the selected compatibility set and referenced values;
2. acquire and renew a Lease for this Foreman release;
3. create revision-owned Candlepin, Pulp, and Foreman migration Jobs and wait;
4. roll and verify Foreman/Katello, Pulp, Candlepin, and Dynflow workloads;
5. roll the paired execution proxy;
6. run the final service and execution checks, then publish `Ready`.

The Lease is held only for one operation, renewed while a non-quiescent phase
is active, and released after `Ready` or `Blocked`. Its expiry permits another
controller instance to resume observation after a crash; it never authorizes a
second migration Job. Revision Jobs require the ForemanRelease UID and
operation ID as labels, and reconciliation must adopt an existing matching Job
before considering creation.

It does not own PostgreSQL, Valkey, Artemis, object storage, PKI, edge Smart
Proxies, DHCP, DNS, or TFTP. It also never restores a database or performs an
automatic Helm rollback after migrations.

## Failure and retry contract

`operator/release-state-machine.json` is the machine-readable transition
contract. Any failed validation, migration, rollout, or verification moves the
resource to `Blocked` with a condition and keeps the last known application
revision running where Kubernetes can do so safely. A retry is accepted only
after the operator observes a changed `spec.retryToken`; merely reconciling the
same failed object cannot restart migration Jobs.

`spec.paused` prevents the next phase from starting. It does not kill a running
migration Job, terminate a rollout, or cancel active Remote Execution work.
The controller observes the current phase to a safe boundary and then remains
paused.

Every observed ForemanRelease receives the
`platform.theforeman.org/release-protection` finalizer before work starts.
Deleting the CR never uninstalls Helm releases or deletes application data. It
first requests the same safe pause, waits for an active migration or rollout
to reach its observable boundary, proves ownership of the operation Lease,
releases it, and then removes the finalizer. A replacement leader waits for a
live previous holder and can finish deletion only after safely claiming an
expired Lease. A forced manual finalizer removal bypasses that safety
contract and is reserved for recovery when no controller can be restored.

`spec.failurePolicy.afterMigration` intentionally accepts only `Halt`. A future
API version may add separately authorized restore orchestration, but it must
not reinterpret Deployment rollback as database rollback.

The status uses the conventional `Available`, `Progressing`, `Degraded`, and
`Paused` condition types. Conditions describe durable observations; `phase`
selects the next state-machine transition. Every status write carries the
observed resource generation so a client can distinguish current state from a
stale controller report.

## Current boundary

The CRD and state graph are statically validated by `tests/operator-contract.rb`.
`tests/operator-state-machine.rb` also executes the complete happy path, pause,
blocked retry, busy Lease, invalid transition, conditions, and operation
replacement and progress-checkpoint behavior. `tests/operator-reconciler.rb` simulates a controller
restart during migration, safe-boundary pause, a failed validation, and an
explicit retry. The two-candidate controller, leader takeover, bounded RBAC,
chart, and publication image are present and covered by command-level
simulations. Real-cluster tests
of the published image are still required before treating the controller path
as production-ready.
