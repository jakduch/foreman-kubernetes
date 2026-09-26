# Candlepin high availability

Candlepin can run more than one request-serving pod only when its two internal
coordination mechanisms are shared. This chart makes that an explicit opt-in
contract rather than treating `replicas` as a sufficient HA switch.

## Required external services

1. All replicas use the same PostgreSQL database.
2. Artemis runs outside the Candlepin pods and is reachable through an Artemis
   core client URL stored in `candlepin-runtime` under
   `artemis-broker-url` (or the configured `brokerUrlSecretKey`).
3. Optional broker client material is supplied by a Secret mounted read-only at
   `/etc/candlepin/artemis`. Paths in the broker URL may refer to files there.

The external broker must provision the durable addresses and queues from
Candlepin's embedded broker contract before Candlepin starts:

| Address | Routing type | Queue |
| --- | --- | --- |
| `event.default` | multicast | `event.org.candlepin.audit.LoggingListener` |
| `event.default` | multicast | `event.org.candlepin.audit.ActivationListener` |
| `job` | anycast | `jobs` |

The disposable Kind harness creates these queues explicitly after its Artemis
Deployment becomes ready. Production broker automation must provide the same
topology; enabling address or queue auto-creation alone is insufficient because
Candlepin opens named consumers during application initialization.

The current Candlepin client creates sessions without separate username and
password parameters and logs the broker URL while initializing. Prefer a
broker that authenticates a TLS client certificate. Do not place a reusable
broker password or a private-store password in the URL unless the resulting
log exposure is accepted and contained.

## Scheduler coordination

HA mode configures the JDBC Quartz store with:

- a common scheduler instance name;
- `org.quartz.scheduler.instanceId=AUTO`, giving every running pod a unique
  scheduler identity;
- `org.quartz.jobStore.isClustered=true`;
- a configurable cluster check-in interval, defaulting to 15 seconds.

The database clock must be synchronized across the PostgreSQL service and
Kubernetes nodes. Scheduler failover is bounded by Quartz's check-in and
misfire behavior, so the integration drill must include terminating the pod
that owns a running trigger.

## Migration ownership

When `migrations.enabled=true`, a revision-specific Job runs Candlepin's bundled
Liquibase changelog before the application becomes healthy. The database
password is passed through Liquibase's environment-variable interface and is
not rendered into a ConfigMap or command line. Normal Candlepin pods use
`candlepin.db.database_manage_on_startup=HALT`; they refuse to start while a
changeset is pending instead of racing to modify the schema.

The migration wrapper depends on the filesystem contract of the Foreman
Candlepin RPM image (`/usr/share/candlepin/liquibase.sh` and the expanded webapp
below `/var/lib/tomcat/webapps/candlepin`). A different Candlepin base image
must provide the same layout or its own migration command.

## Upgrade boundary

The Deployment deliberately retains the `Recreate` strategy. More than one
replica protects request service from a pod or node failure during normal
operation, but this first HA slice does not claim a zero-downtime schema
upgrade. `ForemanRelease` now creates and finishes the Candlepin migration Job
before it submits the application Helm revision. Replacing `Recreate` with a
rolling strategy still requires runtime proof that both adjacent Candlepin
versions can safely serve during every supported schema transition.

## Values example

```yaml
candlepin:
  replicas: 2
  highAvailability:
    enabled: true
    brokerUrlSecretKey: artemis-broker-url
    existingBrokerTlsSecret: candlepin-artemis-tls
    quartz:
      instanceName: ForemanCandlepinCluster
      clusterCheckinInterval: 15000
```

When restricted egress is enabled, also identify the broker without relying on
its DNS name:

```yaml
networkPolicy:
  egress:
    external:
      candlepin:
        peers:
          - ipBlock:
              cidr: 192.0.2.12/32
        ports:
          - 61616
```

The disposable amd64 drill now sends concurrent, CA-verified HTTPS requests
directly to both pod IPs while retaining the Service certificate hostname. It
then queues a real owner-healing job through Katello's authenticated Candlepin
client, requires one successful execution attempt on exactly one live
Candlepin pod, restarts Artemis completely, and requires another one-attempt
job without replacing either Candlepin pod. The report is retained with the
integration evidence. It remains an implemented-but-unrun contract until the
pinned image workflow completes.

The same drill advances the existing `ExpiredPoolsCleanupJob` trigger in the
disposable Quartz database, observes its origin and single execution, deletes
that scheduler pod, waits until its stale cluster row is replaced, and advances
the trigger again. The second job must be created by another live scheduler and
must also execute exactly once.

The full integration harness also injects invalid credentials into a distinct
Candlepin migration operation. It requires the current two replicas to remain
unchanged, restores the Secret, and then requires a successful roll-forward to
replace both replicas through the `Recreate` strategy and reconstruct the
two-member Quartz cluster. A trigger already handed to an asynchronous worker
is covered by the separate Artemis delivery contract; Quartz ownership failover
is covered at the trigger boundary described above. These remain prepared
contracts until the pinned amd64 workflow completes.
