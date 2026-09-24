# Disposable kind integration test

`run.sh` creates a dedicated single-node kind cluster, installs ingress-nginx, PostgreSQL, Valkey, generated short-lived PKI, and the complete chart. It then verifies:

- initial Pulp and Foreman migrations;
- Foreman health both with and without the optional client certificate;
- automatic Pulp Smart Proxy registration through the private mTLS endpoint;
- absence of a public Pulp administrative API route;
- Dynflow worker scaling;
- a second Helm revision with migration gates and a Foreman rollout.

The test is intentionally opt-in because it downloads the real application images and needs substantially more CPU, memory, and time than chart rendering:

```sh
tests/kind/run.sh
```

The temporary cluster and generated PKI are removed on success or failure. Set `KEEP_CLUSTER=1` only while diagnosing a failure. An existing cluster with the same name is never modified unless `REUSE_CLUSTER=1` is explicit.

By default the harness uses the digest-pinned nightly candidate under `profiles/`. The published application images are currently `linux/amd64` only. The script refuses an ARM host unless `ALLOW_EMULATION=1` explicitly opts into the slower, host-dependent emulation path. `IMAGE_PROFILE=/absolute/path/to/values.yaml` selects another candidate set.
