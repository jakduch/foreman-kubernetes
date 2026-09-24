# Verified runtime contracts

These contracts were taken from the current upstream source snapshots listed in the README.

## Foreman image

- Declares the `foreman` user and group as UID/GID 994 and ends its image build
  with `USER foreman`.
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

- Ends its image build with `USER tomcat`; the chart requires that resolved
  identity to be non-root but does not hard-code an RPM-owned UID.
- Runs Tomcat using `/usr/libexec/tomcat/server start`.
- Exposes an unauthenticated `/candlepin/status` endpoint.
- Runs database management during application startup by default.
- Uses a JDBC Quartz job store, but the current deployed configuration does not enable `org.quartz.jobStore.isClustered`.
- Uses an embedded Artemis broker by default (`vm://0`). Multiple replicas would not share that queue.
- The Foreman RPM image contains Liquibase, the expanded Candlepin webapp, and
  `/usr/share/candlepin/liquibase.sh`; the chart migration wrapper uses that
  image-specific layout.
- The external broker client reads
  `candlepin.audit.hornetq.broker_url`. Its session factory does not expose
  separate username/password settings and logs the configured URL.

The chart permits multiple replicas only through the explicit HA contract. It
disables the embedded broker, uses the external URL from a Secret, clusters
Quartz with an automatically unique instance ID, and transfers schema
ownership to a revision Job. Full image-level integration proof is still
pending.

## Pulp image

- Declares the `pulp` user and group as UID/GID 700 and ends its image build
  with `USER pulp:pulp`.
- Provides separate `pulpcore-api`, `pulpcore-content`, and `pulpcore-worker` executables.
- API defaults to port 24817 and content to port 24816 in the current foremanctl contract.
- Migration command: `pulpcore-manager migrate --noinput`.
- Every role requires a shared database, Valkey, symmetric key, and content
  storage. The chart supports either a shared filesystem or Pulpcore's
  `storages.backends.s3.S3Storage` backend.
- S3 mode uses `/var/lib/pulp/tmp` only as per-pod scratch space and can redirect
  downloads to signed object-store URLs.
- The `pulp_smart_proxy` plugin exposes Foreman-compatible feature discovery below `/pulp/api/v3/smart_proxy` and advertises `PULP_SMART_PROXY_PULP_URL` as Katello's API base URL.
- Katello currently builds generated Pulp clients from the advertised URL's scheme and hostname, without retaining a non-default port. The internal control Service therefore exposes HTTPS on port 443 while its unprivileged proxy container listens on 8443.
- Pulp remote-user authentication reads `HTTP_REMOTE_USER`; the chart sets it only behind a private mTLS proxy after validating the client certificate common name.
- Pulp Certguard reads a URL-escaped PEM certificate from `X-CLIENT-CERT` for protected content downloads.
- The Pulp Smart Proxy advertises the public Foreman `/rhsm` URL separately from its private API URL, so host registration never receives a cluster-internal Service hostname.

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

- `candlepin-runtime`: `database-password`; in HA mode it also contains the
  configured `artemis-broker-url` key.
- `candlepin-certificates`:
  - `candlepin-ca.crt`
  - `candlepin-ca.key`
  - `tomcat.crt`
  - `tomcat.key`

The chart generates `candlepin.conf`, `server.xml`, `tomcat.conf`, `logging.properties`, and `logback.xml`. SmallRye environment overrides supply the database and OAuth secrets with a higher priority than the generated properties file. A separate optional Secret supplies `db-ca.crt` when database certificate validation is enabled. HA deployments may additionally mount a broker TLS Secret at `/etc/candlepin/artemis`; its filenames are referenced from the secret broker URL rather than copied into generated configuration.

### `pulp-runtime` and `pulp-config`

`pulp-runtime` contains `database-password` and `django-secret-key`. `pulp-config` contains `database_fields.symmetric.key`. The chart generates all non-secret Dynaconf environment values, including database host, Valkey URL, content origin, and enabled plugins.

With S3 storage, an optional `pulp-object-storage` Secret contains the selected
access-key, secret-key, and optional session-token keys. Workload identity can
replace that Secret through annotations on Pulp's dedicated ServiceAccount. An
optional object-storage CA Secret supplies the selected CA key through
`AWS_CA_BUNDLE`.

An optional Pulp database CA Secret contains `db-ca.crt`. When configured, the
same trust root is mounted into API, content, worker, migration, and recovery
pods, and Dynaconf receives it as PostgreSQL's `sslrootcert` option.

### Edge and Pulp control certificates

- `pulp-control-proxy-certificates` contains `tls.crt`, `tls.key`, and `ca.crt`.
- The server certificate must cover the chart's Pulp control Service DNS name. Katello validates it with `foreman-certificates/ca.crt` and authenticates with `client_cert.pem` plus `client_key.pem`.
- The ingress TLS Secrets use the standard `tls.crt` and `tls.key` keys.
- `ingress-client-ca` contains `ca.crt` used by ingress-nginx to verify optional client certificates before replacing the upstream certificate headers.

The default trusted common name for the Pulp control plane is `platform.fqdn`; additional names must be listed explicitly in `pulp.controlProxy.trustedClientCommonNames`.
