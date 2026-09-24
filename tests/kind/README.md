# Disposable kind integration test

`run.sh` creates a dedicated single-node kind cluster, installs ingress-nginx, PostgreSQL, Valkey, generated short-lived PKI, and the complete chart. It then verifies:

- initial Pulp and Foreman migrations;
- separate Candlepin migration ownership and two replicas using one external
  Artemis broker plus clustered Quartz;
- Candlepin request-service recovery after deleting one replica, including
  replacement of the terminated Quartz scheduler instance and cleanup of its
  stale cluster row;
- Foreman health both with and without the optional client certificate;
- the chart-owned Helm smoke test against Foreman/Katello aggregate health,
  Candlepin status, and Pulp status through the default NetworkPolicies;
- automatic Pulp Smart Proxy registration through the private mTLS endpoint;
- deployment and API registration of a separate, singleton execution Smart
  Proxy whose advertised features must equal Ansible, Dynflow, and Script;
- real SSH and Ansible command jobs from Foreman against a disposable
  unprivileged target, including verification that Foreman selected the
  registered execution proxy;
- an egress-restricted execution proxy which reaches only cluster DNS, the
  Foreman ingress, and the disposable SSH target, plus a denied connection to
  an unrelated in-cluster content service;
- discovery, import, host assignment, and execution of a disposable Ansible
  role published declaratively to the proxy's content claim;
- replacement of that already imported role with a second revision, followed
  by another synchronization and execution which rejects the stale revision;
- expected-failure and cancellation paths followed by a successful job proving
  the executor remains usable;
- deletion of the execution-proxy Pod after a long-running command reaches the
  target; the task must become terminal and a fresh command must then succeed,
  without claiming transparent continuation of the interrupted SSH process;
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
- execution-proxy re-registration and successful new jobs after the clean
  namespace restore and again after rotating its server TLS, Foreman client
  TLS, and SSH identities and restarting both ends of the SSH trust relation;
- Dynflow worker scaling;
- a deliberately failed Foreman migration caused by temporary invalid database
  credentials: the previous Foreman and Dynflow Pods must remain present, an
  already-running Remote Execution job and a fresh job must succeed, and a
  subsequent healthy revision must run migrations and replace the held Pods;
- a second Helm revision with migration gates and confirmed Foreman and Dynflow
  Pod replacement while a Remote Execution job remains active and completes;
- a configuration-changing execution-proxy rollout while another active job
  completes, followed by a fresh job through the replacement Pod.

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
manual dispatch on an amd64 runner. Successful complete runs retain a
promotion-eligible evidence artifact bound to the exact commit, profiles, and
test contract. Failed runs retain a short-lived diagnostic artifact and always
remove the disposable cluster.

The temporary cluster and generated PKI are removed on success or failure. Set `KEEP_CLUSTER=1` only while diagnosing a failure. An existing cluster with the same name is never modified unless `REUSE_CLUSTER=1` is explicit.

The harness builds `images/recovery-toolbox/Dockerfile` and the test-only
`images/ssh-target/Dockerfile` locally and loads them into kind; it publishes
neither image. The SSH target permits only the generated short-lived public
key for its unprivileged `foreman` user and exists solely inside the disposable
namespace. Set `SKIP_RECOVERY_TEST=1` for a faster diagnostic run that omits
the recovery toolbox build and recovery drill; the SSH target is still built
because execution tests remain active.

By default the harness resolves the paired, digest-pinned nightly candidate
from `compatibility/release-sets.json` and uses a digest-pinned Kubernetes 1.34
kind node. `COMPATIBILITY_SET` selects another declared pair. The published
application images are currently `linux/amd64` only. The script refuses an ARM
host unless `ALLOW_EMULATION=1` explicitly opts into the slower, host-dependent
emulation path. For candidate development, `IMAGE_PROFILE` and
`EXECUTION_PROXY_IMAGE_PROFILE` may override both halves of the pair together;
a one-sided override is rejected. `KIND_NODE_IMAGE=...` selects another
Kubernetes test image.

Set `INTEGRATION_EVIDENCE_FILE` to write a result record after all assertions:

```sh
INTEGRATION_EVIDENCE_FILE=artifacts/integration-result.json tests/kind/run.sh
```

Only a complete native `linux/amd64` GitHub Actions run of the profiles declared
by the selected set is eligible for promotion. Other records remain useful for
diagnosis but cannot change a set to `supported`.
