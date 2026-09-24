# Roadmap

## Next vertical slice

1. Run the opt-in kind integration harness against published image sets and record the first known-compatible digests.
2. Publish the prepared, digest-pinned recovery toolbox workflow output and
   exercise the maintenance-gated backup and restore Jobs in the amd64
   integration environment.
3. Run the clean-namespace recovery drill on amd64 before calling disaster recovery verified.
4. Prove restricted workload security contexts and opt-in egress policies in the amd64 integration environment before making egress isolation a default.
5. Add optional public routes for additional Pulp plugins only when their route and authentication contracts are covered by tests.
6. Exercise the S3-compatible Pulp backend against a real versioned object
   store, including direct downloads, multipart uploads, credential rotation,
   and a coordinated database/bucket restore.
7. Promote packaged plugins individually from the machine-readable inventory;
   each needs migrations, runtime dependencies, one real workflow, restart,
   scale, and recovery proof.
8. Run the prepared central-execution drill against the pinned amd64 image,
   then extend it from prepared successful, failed, and cancelled SSH/Ansible
   jobs, content replacement, fresh jobs after identity rotation, and
   restricted egress to a product decision on retrying interrupted jobs.
   The harness now also prepares controlled Foreman/Dynflow and execution-proxy
   upgrades during active jobs; those assertions require actual Pod replacement,
   successful completion of the in-flight job, and a successful fresh job.

## Implemented, pending integration proof

- The manual full-integration workflow now emits a retained evidence record
  bound to the exact commit, compatibility set, profile hashes, native runner,
  and versioned runtime-check contract. Candidate promotion is explicit and
  rejects local, partial, stale, or incomplete evidence before storing the
  accepted record with the supported set.
- A guarded upgrade helper checks the currently installed application and
  execution proxy, renders both halves of one digest-pinned compatibility set,
  applies application migrations before upgrading the proxy, and reruns health
  checks. It stops on the first failed phase and never performs an unsafe
  manifest-only rollback after database migrations.
- The integration harness now prepares a failed Foreman migration followed by
  a roll-forward revision. It requires the old application and Dynflow Pods to
  remain available through the failure, preserves an active Remote Execution
  job, restores the injected Secret even during cleanup, and replaces the held
  Pods only after the next migration succeeds.
- One-shot, maintenance-gated recovery Jobs produce encrypted Restic snapshots
  of all three databases, Foreman's LDAP avatars, Pulp filesystem storage, and
  application Secrets.
- Restore requires an explicit confirmation value, validates snapshot identity
  and contents before deletion, and keeps recovery RBAC separate from runtime
  ServiceAccounts.
- PostgreSQL servers, database roles, Restic storage, repository credentials,
  and infrastructure-level backups remain external ownership boundaries.
- Normal workloads now run with explicit non-root identities, dropped
  capabilities, runtime-default seccomp, and no Kubernetes API token. Egress
  isolation is implemented but remains opt-in until deployment-specific
  PostgreSQL, Valkey, proxy, and repository destinations are supplied.
- Startup and liveness checks are isolated from dependency-aware readiness,
  and disruption budgets are emitted only for genuinely redundant workloads.
- Pulp can use S3-compatible object storage with a dedicated workload identity,
  optional static credentials and private CA, per-pod scratch space, restricted
  egress validation, and an explicit external bucket recovery boundary.
- A separate singleton execution Smart Proxy chart enables only Dynflow,
  Remote Execution SSH, and Ansible. It persists the current recoverable state,
  mounts Ansible content read-only, models mTLS/SSH identities and optional SSH
  CA trust, and rejects any unexpected advertised feature through readiness.
  The amd64 drill now deploys and registers that proxy, runs real SSH and
  successful, failed, and cancelled SSH jobs, Ansible commands, plus an imported
  and assigned Ansible role against a disposable target. It checks proxy
  selection, permits only the declared ingress and target peers, rejects an
  unrelated in-cluster destination, and repeats the jobs after clean restoration
  and complete proxy TLS/client/SSH identity rotation. It then replaces the
  already imported role with a second revision, synchronizes it again, and
  rejects execution of the stale revision. A running job is also interrupted by
  deleting the proxy Pod; it must leave the task in a terminal state before a
  fresh job proves the restarted proxy is usable. This deliberately does not
  claim transparent handoff of an active SSH process. Configuration-changing
  application and proxy upgrades are also prepared while jobs are active. They
  require successful in-flight completion and reject upgrades that do not
  replace the intended Pods. The drill has not yet been executed against the
  published image set.

## Candlepin HA track

Implemented in the chart, pending amd64 integration proof:

- external Artemis URL and optional TLS material come from Secrets;
- embedded Artemis is disabled in HA mode;
- Quartz JDBC clustering uses a common name and automatic unique instance IDs;
- a dedicated Liquibase Job owns database changes while application pods use
  `HALT`;
- replicas greater than one require the full HA and migration contract;
- topology spread and a disruption budget protect redundant pods.

Still required:

1. Prove one-time Artemis job delivery and reconnect behavior.
2. Run the prepared Quartz membership and stale-instance failover assertion on
   amd64; the harness now terminates one scheduler pod and requires a distinct
   replacement while retaining exactly two live cluster rows.
3. Exercise failed and successful migrations against the pinned image set.
4. Move migration-before-rollout sequencing into the operator, then replace
   `Recreate` with a proven rolling strategy.

## Operator track

The namespaced `ForemanRelease` CRD and machine-readable lifecycle graph now
define phase ordering, status conditions, same-namespace values references,
pause semantics, explicit blocked retries, and the no-database-rollback rule.
The side-effect-free controller core executes that graph and is covered across
success, pause, retry, contention, and invalid transitions, but no
cluster-facing reconciliation process is running yet. Its reconciliation loop
now persists each phase before acting, resumes one deterministic operation
after restart, and gives controller-owned migration and registration Jobs
stable names plus owner labels for adoption.
The first Kubernetes boundary now resolves digest-pinned in-image profiles,
reads same-namespace values Secrets, and uses an optimistic resource-version
precondition for status writes; Helm phase execution and Lease/Job observation
remain to be connected.
The renewable Lease implementation is now available to that adapter and is
covered for creation, restart adoption, foreign-owner contention, expiration,
renewal, and race-safe release. Helm phase execution and Job/rollout
observation remain to be connected.

After the Helm lifecycle and runtime contracts are proven, add a small Go operator that:

- validates compatible Foreman/Katello/Candlepin/Pulp version sets;
- creates migration Jobs and waits for their completion before rolling workloads;
- reports component health in a custom resource status;
- performs controlled upgrades and rollback gating;
- manages Smart Proxy registration without taking ownership of edge DHCP/DNS networks.
