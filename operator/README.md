# Foreman release operator contract

This directory defines the API and deterministic lifecycle contract for the
release controller. `operator/lib/foreman_release/state_machine.rb` is the
executable, side-effect-free transition core used to build durable status,
conditions, operation identity, explicit retries, and pause observations. A
cluster-facing reconciliation process is not running yet.

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
replacement behavior. A controller image, RBAC, Lease renewal, Job adoption,
status patching, and restart/idempotency integration tests are still required
before installing the CRD in a cluster.
