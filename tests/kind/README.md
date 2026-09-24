# Disposable kind integration test

`run.sh` creates a dedicated single-node kind cluster, installs ingress-nginx, PostgreSQL, Valkey, generated short-lived PKI, and the complete chart. It then verifies:

- initial Pulp and Foreman migrations;
- separate Candlepin migration ownership and two replicas using one external
  Artemis broker plus clustered Quartz;
- Candlepin request-service recovery after deleting one replica, including
  replacement of the terminated Quartz scheduler instance and cleanup of its
  stale cluster row;
- Foreman health both with and without the optional client certificate;
- automatic Pulp Smart Proxy registration through the private mTLS endpoint;
- absence of a public Pulp administrative API route;
- a Katello content lifecycle against an in-cluster deterministic file source:
  organization and product creation, repository synchronization, public Pulp
  content delivery, Content View publication, and Activation Key assignment;
- an encrypted Restic backup of all three PostgreSQL databases, Pulp storage,
  and the declared Secret escrow;
- restoration after deliberately changing independent probes, deleting the
  entire application namespace, recreating empty databases and Pulp storage,
  and retaining application state only in the Restic repository;
- Foreman readiness and Pulp registration after leaving restore maintenance;
- the complete Katello object graph and published file after restoration, so
  the recovery check covers real application state in addition to probes;
- Dynflow worker scaling;
- a second Helm revision with migration gates and a Foreman rollout.

The test is intentionally opt-in because it downloads the real application images and needs substantially more CPU, memory, and time than chart rendering:

```sh
tests/kind/run.sh
```

The test Artemis broker deliberately allows anonymous connections because the
current Candlepin client does not expose independent broker credentials. It is
an in-namespace disposable dependency, not a production recommendation. Its
Apache Artemis 2.57.0 amd64 image is pinned to the verified platform digest in
`dependencies.yaml`. The
`Full integration` GitHub Actions workflow exposes the same drill through a
manual dispatch on an amd64 runner. Failed runs retain a short-lived diagnostic
artifact and always remove the disposable cluster.

The temporary cluster and generated PKI are removed on success or failure. Set `KEEP_CLUSTER=1` only while diagnosing a failure. An existing cluster with the same name is never modified unless `REUSE_CLUSTER=1` is explicit.

The harness builds `images/recovery-toolbox/Dockerfile` locally and loads it
into kind; it does not publish that test image. Set `SKIP_RECOVERY_TEST=1` for a
faster install-only diagnostic run that omits the toolbox build and recovery
drill.

By default the harness uses the digest-pinned nightly candidate under
`profiles/` and a digest-pinned Kubernetes 1.34 kind node. The published
application images are currently `linux/amd64` only. The script refuses an ARM
host unless `ALLOW_EMULATION=1` explicitly opts into the slower, host-dependent
emulation path. `IMAGE_PROFILE=/absolute/path/to/values.yaml` selects another
candidate set; `KIND_NODE_IMAGE=...` selects another Kubernetes test image.
