# Roadmap

## Next vertical slice

1. Run the opt-in kind integration harness against published image sets and record the first known-compatible digests.
2. Publish the prepared, digest-pinned recovery toolbox workflow output and
   exercise the maintenance-gated backup and restore Jobs in the amd64
   integration environment.
3. Run the clean-namespace recovery drill on amd64 before calling disaster recovery verified.
4. Retain a successful amd64 run of the prepared `restricted` Pod Security
   admission and opt-in egress-policy drills before making egress isolation a
   default.
5. Add optional public routes for additional Pulp plugins only when their route and authentication contracts are covered by tests.
6. Retain a successful amd64 run of the prepared versioned, multipart Pulp S3
   qualification, then extend it to a coordinated database/bucket restore
   against a production provider.
7. Promote packaged plugins individually from the machine-readable inventory;
   each needs migrations, runtime dependencies, one real workflow, restart,
   scale, and recovery proof.
   Foreman Webhooks now has that drill prepared, including HTTP failure
   visibility, destination correction, receiver replacement, and clean
   database recovery; the amd64 run is still pending.
   Foreman virt-who Configure now has its application-side drill prepared:
   invalid KubeVirt input, libvirt configuration, encrypted reporting identity,
   generated external-host script, report state, cleanup, and clean recovery.
   Execution of that script and a real Candlepin report remain an external-host
   qualification step rather than a Kubernetes workload.
   Foreman KubeVirt additionally remains blocked on shipping the prepared
   dynamic API-version discovery fix; the packaged plugin currently forces
   `v1alpha3`. Its fog dependency also needs the prepared namespace-scoping fix
   so network attachment discovery does not require cluster-wide access, plus
   the request-body fix that emits `kubevirt.io/v1` rather than plain `v1`. An
   additional plugin fix makes failed Kubernetes and KubeVirt probes produce
   model validation errors instead of silently returning `false`. The patch
   series also preserves explicitly non-bootable image data disks and removes
   PVCs created before a later disk creation fails. It also keeps PVCs intact
   when Kubernetes rejects VM deletion. An
   external-cluster lifecycle is prepared to compare discovery,
   create a stopped VM/PVC, survive database recovery and application upgrades,
   and clean up. Run it only after an image containing the fix is available;
   a mocked API is not promotion evidence.
8. Run the prepared central-execution drill against the pinned amd64 image,
   then extend it from prepared successful, failed, and cancelled SSH/Ansible
   jobs, content replacement, fresh jobs after identity rotation, and
   restricted egress to a product decision on retrying interrupted jobs.
   The harness now also prepares controlled Foreman/Dynflow and execution-proxy
   upgrades during active jobs; those assertions require actual Pod replacement,
   successful completion of the in-flight job, and a successful fresh job.

## Implemented, pending integration proof

- The Katello content lifecycle now builds a deterministic local APT repository
  and Debian package alongside its File and Python fixtures. It synchronizes the
  package, publishes it in the same Content View, and verifies library and
  published content again after clean-namespace recovery. Promotion records
  require this Debian workflow, but it remains unverified until the amd64 drill
  has run against the pinned images.

- Foreman KubeVirt now has an opt-in external qualification path. It reads the
  bearer token and CA from files, stores no credential in its state artifact,
  compares the plugin's selected API version with live cluster discovery,
  validates the requested StorageClass, creates a stopped pod-network VM and
  PVC, checks them after clean database recovery and later rollouts, and deletes
  both even through a direct API fallback. This does not run in the default
  Kind drill and cannot pass against the current packaged `v1alpha3` override.

- Foreman virt-who Configure now has a prepared API lifecycle against the same
  organization used by the Katello content drill. It verifies that invalid
  KubeVirt input is rejected, ordinary API responses omit hypervisor passwords,
  the hidden reporting identity is encrypted at rest and minimally assigned,
  a libvirt endpoint update regenerates the deployment script, a report touch
  changes state from `unknown` to `ok`, and all state survives clean namespace
  recovery. Deleting the last configuration must also delete its service
  identity. The test deliberately does not execute the generated RPM/systemd
  script inside Kubernetes.

- Foreman web request continuity now has a prepared public-ingress drill: eight
  concurrent clients issue 640 dependency-aware health requests while one of
  two ready web Pods is deleted and replaced. Any connection failure, non-200
  response, or unhealthy Foreman/Katello result fails promotion. The test does
  not claim a throughput limit until a dedicated capacity environment exists.
- Pulp API and content continuity now have a paired drill using the private API
  Service and a checksum-verified public artifact. It removes one Pod from each
  independently scalable Deployment under concurrent traffic and requires both
  Services to remain correct while replacements become ready.
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
- The integration harness now prepares independent failed Foreman and Candlepin
  migrations followed by one roll-forward revision. It requires every old
  application workload Pod to remain available through both failures,
  preserves an active Remote Execution job, restores either injected Secret
  even during cleanup, and replaces the affected Foreman, Dynflow, and
  `Recreate`-managed Candlepin Pods only after all migrations succeed.
- The same full-stack workflow now installs both release-controller replicas,
  adopts the running application and execution-proxy releases, proves that a
  real failed migration remains blocked without a retry-token change, deletes
  the active leader, and requires the standby to complete the authorized retry
  and final managed-host execution. The same drill now mutates a chart-owned
  stateless ConfigMap and PVC separately: it requires an automatic repair for
  the ConfigMap, an explicit block for the PVC, and a fresh retry token after
  the PVC is restored. A referenced Secret resource-version change has its own
  migration-free repair assertion, anonymous per-release fingerprint, and
  workload replacement check. The drill also records the earliest validated
  certificate expiry published by the controller.
- A chart-owned Helm test and the full-stack workflow now exercise the exact
  Pulp image against a digest-pinned S3-compatible endpoint, including bucket
  versioning, multipart write/read integrity, signed direct downloads,
  delete-marker visibility, recovery from an exact older object `VersionId`,
  cleanup, rejected retired credentials, and a complete repeat after Secret
  rotation, with a separate evidence record.
- One-shot, maintenance-gated recovery Jobs produce encrypted Restic snapshots
  of all three databases, Foreman's LDAP avatars, Pulp filesystem storage, and
  both releases' Secrets plus execution Dynflow/runner and Ansible-content
  claims. The guarded path stops application dispatchers and the paired
  execution proxy before a Job can access that recovery set.
- S3 recovery now has a guarded two-phase hand-off: both releases are quiesced
  before an external bucket point is captured or restored, its exact provider
  ID is integrity-protected in the recovery manifest, and a mismatched ID is
  rejected before database replacement. A real provider snapshot/restore drill
  is still required before this boundary is considered qualified.
- Restore requires an explicit confirmation value, validates snapshot identity
  and contents before deletion, and keeps recovery RBAC separate from runtime
  ServiceAccounts.
- PostgreSQL servers, database roles, Restic storage, repository credentials,
  and infrastructure-level backups remain external ownership boundaries.
- Normal workloads now run with explicit non-root identities, dropped
  capabilities, runtime-default seccomp, and no Kubernetes API token. Egress
  isolation is implemented but remains opt-in until deployment-specific
  PostgreSQL, Valkey, proxy, and repository destinations are supplied.
- The disposable Kubernetes 1.34 environment now enforces the versioned
  `restricted` Pod Security Standard before installing product workloads. Its
  broker, object-storage, and SSH lifecycle fixtures are non-root and are
  recreated after enforcement, so upgrades, recovery, credential rotation,
  and controller retries cannot silently introduce a noncompliant Pod.
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

1. Run the prepared one-time Artemis delivery and in-process reconnect drill on
   amd64. It now executes a real owner-healing job before and after a complete
   broker restart, rejects redelivery, and rejects hidden Candlepin restarts.
2. Run the prepared Quartz trigger ownership failover assertion on amd64; the
   harness now forces the real `ExpiredPoolsCleanupJob` trigger, deletes the
   scheduler that fired it, requires a distinct replacement while retaining
   exactly two live cluster rows, and requires one execution after takeover.
3. Run the prepared failed Foreman and Candlepin migration roll-forward against
   the pinned image set, including the Candlepin `Recreate` replacement.
4. Run the prepared operator adoption, blocked retry, and leader-takeover drill
   against the pinned images. Replace `Recreate` with a rolling strategy only
   after adjacent-version schema compatibility is proven.

## Operator track

The namespaced `ForemanRelease` CRD and machine-readable lifecycle graph now
define phase ordering, status conditions, same-namespace values references,
pause semantics, explicit blocked retries, and the no-database-rollback rule.
The Ruby controller now executes that graph against the Kubernetes API and
Helm. It resolves digest-pinned profiles, reads same-namespace values Secrets,
persists status with an optimistic resource-version precondition, adopts
deterministic migration and verification Jobs, observes rollout deadlines,
rolls and verifies the paired execution proxy, and starts a migration-free
repair after a Ready audit detects missing stateless resources or an
out-of-band Helm revision, while missing stateful claims block for explicit
recovery. Two candidates use a
short-lived leader Lease while the separate renewable release Lease fences all
controller and manual writers. Command-level simulations cover leader
takeover, restart adoption, foreign-owner contention, expiration, renewal,
race-safe release, Ready drift repair, safe referenced-Secret rollout, and the
no-rollback boundary.

The remaining operator work is real-cluster qualification of the published
image and exact compatibility set plus retained evidence rather than another
parallel implementation. The prepared Kind drill now covers failure, leader
takeover, stateless drift repair, valid Secret rotation, stateful drift
blocking, explicit recovery, and certificate-expiry observation, but it has
not been run. The CRD now stores
`v1beta1` while continuing to serve the schema-compatible `v1alpha1` API.
Prometheus alerts and an opt-in Grafana dashboard are now packaged, pending
integration with a real monitoring stack.
