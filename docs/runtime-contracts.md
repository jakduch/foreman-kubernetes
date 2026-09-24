# Verified runtime contracts

These contracts were taken from the current upstream source snapshots listed in the README.

## Foreman image

- Declares the `foreman` user and group as UID/GID 994 and ends its image build
  with `USER foreman`.
- Runs Rails in production on `0.0.0.0:3000`.
- Accepts Puma worker/thread counts through `FOREMAN_PUMA_WORKERS`, `FOREMAN_PUMA_THREADS_MIN`, and `FOREMAN_PUMA_THREADS_MAX`.
- Loads Katello through `FOREMAN_ENABLED_PLUGINS`; Katello is not a standalone server.
- Exposes `/api/v2/ping`, including plugin health results. The endpoint returns
  HTTP 200 even when a nested check reports failure, so the chart parses its
  JSON response for database, cache, and Katello dependency health.
- Database migration and seed command: `bin/rails db:migrate && bin/rails db:seed`.

## Dynflow

- Entry point: `/usr/libexec/foreman/sidekiq-selinux -e production -r ./extras/dynflow-sidekiq.rb -C <config>`.
- `extras/dynflow-sidekiq.rb` allows only one active orchestrator through a Redis lock.
- General and hosts-queue workers can be scaled separately from the orchestrator.
- The orchestrator uses a `Recreate` rollout because a replacement blocks on
  that lock before Sidekiq can announce readiness. Worker and orchestrator Pods
  become Ready only after Sidekiq's post-initialization `startup` event.
- Shutdown removes readiness at Sidekiq's `quiet` event and allows five minutes
  for in-flight work, matching the upstream systemd service stop allowance.

## Central execution Smart Proxy

The execution profile was reviewed against Smart Proxy
`c2af3d35497058fd7dc8146dcbca3adf60334b9e`, Smart Proxy Dynflow
`a07e3fa37aca20f2038e8f469f88c545c39276ff`, Remote Execution SSH
`1ad66baae4498f7f3a5e3cc939ddf20e188336d2`, and Smart Proxy Ansible
`080753705e26a6a9aaa68a413a6935c9ac48c8ad`.

- The official proxy image runs as UID/GID 991, listens on HTTPS 8443, and
  packages `remote_execution_ssh`, `ansible`, and `container_gateway`.
- `FOREMAN_PROXY_ENABLED_PLUGINS` can keep `container_gateway` out of Bundler;
  REx and Ansible bring the required `smart_proxy_dynflow` dependency.
- The legacy `/features` endpoint returns only running plugin names. Current
  REx advertises the feature name `script`, not its package name, so the exact
  execution allow-list is `ansible`, `dynflow`, and `script`.
- HTTPS requires a client certificate at the TLS layer. The local readiness
  check uses the mounted Foreman client identity and compares that exact list.
- Smart Proxy Dynflow is memory-only unless `:database` or
  `DYNFLOW_DB_CONN_STRING` is configured. The chart uses SQLite on the state
  claim.
- Remote Execution SSH requires both the private key and adjacent `.pub` file.
  SSH socket paths must remain at most 49 characters.
- The REx provider retains some job storage in process memory, while Ansible
  runner artifacts and working directories are local. No active-job handoff
  protocol exists, so the current chart contract is one replica with
  `Recreate`.
- Ansible discovers roles and collections below `/etc/ansible` and the system
  paths. Metadata imported into Foreman does not copy that content to the
  executor.

## Katello health

Katello extends Foreman's ping response. Its checks expect:

- Candlepin at `/candlepin/status` with mode `NORMAL`;
- Pulp status with database and Redis connectivity;
- at least one online Pulp worker and content app;
- Foreman Tasks executors and the Katello event daemon.

Katello starts its event daemon lazily from Rails middleware and coordinates a
singleton only through a PID file below the local Rails `tmp` directory. That
does not provide cross-pod exclusion. The chart disables it by default in every
Foreman-derived process and runs it in one dedicated `Recreate` Deployment.
That process publishes a local heartbeat only while Katello reports its event
poller as running; readiness and liveness use the heartbeat, while event status
continues to be shared with web pods through the configured Redis Rails cache.
Katello also passes some uploads and manifests to Dynflow by a path below
`Rails.root/tmp`; the chart mounts one RWX claim there for every Foreman-derived
process so an asynchronous step can run on a different pod.

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
- The image wrappers give API/content requests a 90-second Gunicorn timeout and
  recycle API workers after a jittered number of requests. Because the chart
  invokes the underlying executables directly to retain configurable bind
  ports, it supplies those same settings explicitly through Helm values.
- API defaults to port 24817 and content to port 24816 in the current foremanctl contract.
- Migration command: `pulpcore-manager migrate --noinput`.
- Every role requires a shared database, Valkey, symmetric key, and content
  storage. The chart supports either a shared filesystem or Pulpcore's
  `storages.backends.s3.S3Storage` backend.
- Worker readiness requires the current Pod's Pulpcore database heartbeat, so
  Helm cannot report a worker Deployment available before it has joined the
  task pool. Worker Pods receive a one-hour termination grace period by
  default because Pulpcore handles SIGTERM by finishing an active task; reduce
  it only when interrupted synchronization and publication tasks are accepted.
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

All four key names are configurable. Runtime processes receive only the
database URL and encryption key; the two seed credentials are exposed only to
the Foreman migration-and-seed Job.

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
- The guarded installer and upgrade helper require those TLS and client-CA
  Secrets to exist before changing releases. The Foreman ingress maps verified
  client identity to `HTTP_SSL_CLIENT_CERT`, `HTTP_SSL_CLIENT_S_DN`, and
  `HTTP_SSL_CLIENT_VERIFY`; its middleware decodes ingress-nginx's escaped PEM
  before Foreman or Katello parses it.

The default trusted common name for the Pulp control plane is `platform.fqdn`; additional names must be listed explicitly in `pulp.controlProxy.trustedClientCommonNames`.

## Existing Secret rotation

Helm cannot detect a content-only update to an existing Secret. Several keys
are also mounted through `subPath`, which means Kubernetes does not replace the
file inside an already running container. After applying any referenced
credential, certificate, CA, image-pull, or encryption Secret, change
`secretRolloutToken` in the same reviewed Helm revision. Every long-running
Foreman, Dynflow, Katello event, Candlepin, Pulp, control-proxy, and recurring
task template includes the token hash and is therefore recreated.

The token does not make a CA replacement atomic. For CA rotation, first deploy
a trust bundle containing the old and new roots and change the token. Then
issue and deploy new leaf identities and change the token again. Remove the old
root only after all peers use the new identity, followed by a third token
change. Pulp's database-fields encryption key requires an application-aware
data re-encryption procedure; it must not be treated as an ordinary TLS key
rotation.
