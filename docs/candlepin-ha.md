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
upgrade. The future operator must finish the migration Job, verify the schema,
and only then roll a new application revision.

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

Before production use, prove all of the following with the pinned amd64 image
set: concurrent requests through both pods, single job delivery, Quartz trigger
failover, broker reconnection, a failed migration, and a `Recreate` upgrade.
