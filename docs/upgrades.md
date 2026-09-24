# Controlled upgrades

Foreman/Katello, Candlepin, Pulp, and the execution Smart Proxy are released
independently, but they must be qualified and deployed as one compatibility
set. The `ForemanRelease` controller owns this sequencing for managed
installations. `scripts/upgrade-release.sh` remains the guarded manual path for
environments that have not adopted the controller.

## Preconditions

The helper upgrades existing releases; it is not an installer. It requires:

- an existing application release and execution-proxy release;
- current application health through the chart-owned Helm smoke test;
- a Ready execution-proxy Pod;
- one application values file and one execution-proxy values file containing
  the environment-specific configuration and Secret references;
- a `supported` entry in `compatibility/release-sets.json`.

Before reading release health, the helper atomically acquires the namespaced
`foreman-kubernetes-release` Lease shared with the install helper. Another
invocation stops and reports its holder instead of racing Helm. The process
renews the Lease throughout the operation and removes it only while it still
carries its own holder identity. After an untrappable process or host failure,
the Lease expires and the next helper claims it with an optimistic
`resourceVersion` update; simultaneous takeovers cannot both succeed.

Candidate sets are accepted only with `ALLOW_CANDIDATE=1`. This is intended for
qualification environments and does not promote the set. Retired sets are
always rejected. The selected image profiles are applied after the
environment-specific values, so their digest-pinned image references cannot be
silently replaced by a moving tag in those files.

## Sequence

```text
current smoke test + proxy readiness
                |
                v
render both releases from one compatibility set
                |
                v
verify StorageClass, IngressClass, Metrics API, external PVC/ServiceAccount, and Secret contracts
                |
                v
application upgrade -> migration Jobs -> application smoke test
                |
                v
execution-proxy upgrade -> proxy readiness -> final application smoke test
```

Foreman and Pulp processes use schema-checking init containers. Candlepin uses
the same idempotent Liquibase update command in both its revision Job and a Pod
init barrier. Whichever acquires Liquibase's database lock first performs the
update; the other confirms it, and Tomcat cannot start before that succeeds.
Foreman's recurring CronJobs use the Foreman schema barrier as well, so a task
scheduled during an upgrade cannot start new application code against a schema
that is still being migrated.

Run a supported set with:

```sh
NAMESPACE=foreman \
COMPATIBILITY_SET=example-supported-set \
  scripts/upgrade-release.sh \
    /secure/path/application-values.yaml \
    /secure/path/execution-proxy-values.yaml
```

For the current unqualified candidate in a disposable environment:

```sh
ALLOW_CANDIDATE=1 scripts/upgrade-release.sh \
  /secure/path/application-values.yaml \
  /secure/path/execution-proxy-values.yaml
```

`APPLICATION_RELEASE`, `EXECUTION_RELEASE`, `UPGRADE_TIMEOUT`,
`PREFLIGHT_TIMEOUT`, `RELEASE_LEASE_NAME`, `RELEASE_HOLDER_ID`,
`RELEASE_LEASE_DURATION_SECONDS`, and
`RELEASE_LEASE_RENEW_INTERVAL_SECONDS` may override their defaults. The
renew interval must remain shorter than the duration.

Before the first Helm upgrade, the helper inspects the complete render of both
releases. It verifies every referenced named or default StorageClass,
IngressClass, required resource Metrics API, external PVC, external ServiceAccount, and non-optional external
Secret, including explicitly referenced Secret keys. This is the same
read-only cluster preflight used for a first installation. A missing dependency
therefore fails before any migration Job can advance a database schema.

## Failure and rollback boundary

The helper deliberately does not use `helm upgrade --atomic` and never invokes
`helm rollback`. A successful migration Job may have changed a schema in a way
that an older application image cannot read. Automatically restoring only the
Kubernetes manifests would therefore create a visually successful rollback
with incompatible persistent state.

Failure before the application upgrade leaves both releases unchanged. Failure
during the application upgrade requires inspection of the three migration Jobs
and workload status before retrying. Failure after the application becomes
healthy but before the proxy upgrade leaves a visible split state: keep the
application revision, repair the proxy, and roll it forward using the same set.
Database rollback requires a separately validated recovery point and the
maintenance-gated restore procedure.

The disposable integration harness prepares the failure branch explicitly. It
temporarily gives only a new Foreman migration Job an invalid database URL,
requires Helm to fail, and verifies that every previous Foreman and Dynflow Pod
is still present and serving the in-flight Remote Execution job. After restoring
the Secret, a new revision must complete migrations before those held Pods are
replaced. The cleanup trap also restores the original Secret if the drill exits
between injection and the expected failure.

The final Helm smoke test does not execute a managed-host command. Before the
change window is complete, run a harmless Remote Execution job and the
deployment-specific content workflow. The disposable kind harness contains the
stronger active-job upgrade assertions, but they remain unverified until the
complete pinned amd64 drill runs.

## Release controller boundary

The renewable Lease serializes the supported install, upgrade, and recovery
helpers and the `ForemanRelease` controller. The controller adds durable phase
conditions, migration Job ownership, explicit retry authorization, and
roll-forward sequencing, but it cannot prevent an administrator from bypassing
the Lease with raw Helm. Database rollback remains a separate recovery action,
not a side effect of reverting Deployments.
