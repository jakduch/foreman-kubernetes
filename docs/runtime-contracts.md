# Verified runtime contracts

These contracts were taken from the current upstream source snapshots listed in the README.

## Foreman image

- Runs Rails in production on `0.0.0.0:3000`.
- Accepts Puma worker/thread counts through `FOREMAN_PUMA_WORKERS`, `FOREMAN_PUMA_THREADS_MIN`, and `FOREMAN_PUMA_THREADS_MAX`.
- Loads Katello through `FOREMAN_ENABLED_PLUGINS`; Katello is not a standalone server.
- Exposes `/api/v2/ping`, including plugin health results.
- Database migration and seed command: `bin/rails db:migrate && bin/rails db:seed`.

## Dynflow

- Entry point: `/usr/libexec/foreman/sidekiq-selinux -e production -r ./extras/dynflow-sidekiq.rb -C <config>`.
- `extras/dynflow-sidekiq.rb` allows only one active orchestrator through a Redis lock.
- General and hosts-queue workers can be scaled separately from the orchestrator.

## Katello health

Katello extends Foreman's ping response. Its checks expect:

- Candlepin at `/candlepin/status` with mode `NORMAL`;
- Pulp status with database and Redis connectivity;
- at least one online Pulp worker and content app;
- Foreman Tasks executors and the Katello event daemon.

## Candlepin image

- Runs Tomcat using `/usr/libexec/tomcat/server start`.
- Exposes an unauthenticated `/candlepin/status` endpoint.
- Runs database management during application startup by default.
- Uses a JDBC Quartz job store, but the current deployed configuration does not enable `org.quartz.jobStore.isClustered`.
- Uses an embedded Artemis broker by default (`vm://0`). Multiple replicas would not share that queue.

The chart consequently enforces exactly one Candlepin replica in phase 1.

## Pulp image

- Provides separate `pulpcore-api`, `pulpcore-content`, and `pulpcore-worker` executables.
- API defaults to port 24817 and content to port 24816 in the current foremanctl contract.
- Migration command: `pulpcore-manager migrate --noinput`.
- Every role requires a shared database, Valkey, symmetric key, and content storage.

## Secret keys expected by the chart

### `foreman-runtime`

- `DATABASE_URL`
- `ENCRYPTION_KEY`
- `SEED_ADMIN_USER`
- `SEED_ADMIN_PASSWORD`

### `foreman-shared`

- `candlepin-oauth-secret`

The same key is injected into Foreman's ERB-evaluated Katello settings and Candlepin's SmallRye environment configuration. It is never rendered into a ConfigMap.

### `foreman-certificates`

- `ca.crt`
- `client_cert.pem`
- `client_key.pem`

The chart generates `settings.yaml`, `katello.yaml`, and all three Dynflow queue configurations. It also generates the Candlepin URL from the Helm Service name.

### `candlepin-runtime` and `candlepin-certificates`

- `candlepin-runtime`: `database-password`
- `candlepin-certificates`:
  - `candlepin-ca.crt`
  - `candlepin-ca.key`
  - `tomcat.crt`
  - `tomcat.key`

The chart generates `candlepin.conf`, `server.xml`, `tomcat.conf`, `logging.properties`, and `logback.xml`. SmallRye environment overrides supply the database and OAuth secrets with a higher priority than the generated properties file. A separate optional Secret supplies `db-ca.crt` when database certificate validation is enabled.

### `pulp-runtime` and `pulp-config`

`pulp-runtime` contains `database-password` and `django-secret-key`. `pulp-config` contains `database_fields.symmetric.key`. The chart generates all non-secret Dynaconf environment values, including database host, Valkey URL, content origin, and enabled plugins.
