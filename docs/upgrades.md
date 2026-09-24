# Controlled upgrades

Foreman/Katello, Candlepin, Pulp, and the execution Smart Proxy are released
independently, but they must be qualified and deployed as one compatibility
set. `scripts/upgrade-release.sh` provides the current two-release sequencing
contract until an operator owns this state machine.

## Preconditions

The helper upgrades existing releases; it is not an installer. It requires:

- an existing application release and execution-proxy release;
- current application health through the chart-owned Helm smoke test;
- a Ready execution-proxy Pod;
- one application values file and one execution-proxy values file containing
  the environment-specific configuration and Secret references;
- a `supported` entry in `compatibility/release-sets.json`.

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
application upgrade -> migration Jobs -> application smoke test
                |
                v
execution-proxy upgrade -> proxy readiness -> final application smoke test
```

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

`APPLICATION_RELEASE`, `EXECUTION_RELEASE`, `UPGRADE_TIMEOUT`, and
`PREFLIGHT_TIMEOUT` may override their defaults.

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

The final Helm smoke test does not execute a managed-host command. Before the
change window is complete, run a harmless Remote Execution job and the
deployment-specific content workflow. The disposable kind harness contains the
stronger active-job upgrade assertions, but they remain unverified until the
complete pinned amd64 drill runs.

## Future operator boundary

The script serializes one operator-driven invocation, but it cannot prevent a
second administrator from starting another Helm upgrade, publish component
health as durable status, or decide whether a failed schema migration is safe
to retry. A future controller should add a cluster-side upgrade lock, explicit
phase/status conditions, migration Job ownership, and roll-forward recovery.
It must retain the rule that database rollback is a separate recovery action,
not a side effect of reverting Deployments.
