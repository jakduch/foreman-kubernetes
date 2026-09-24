# Roadmap

## Next vertical slice

1. Run the opt-in kind integration harness against published image sets and record the first known-compatible digests.
2. Publish the recovery toolbox and exercise the maintenance-gated backup and restore Jobs in the amd64 integration environment.
3. Run the clean-namespace recovery drill on amd64 before calling disaster recovery verified.
4. Prove restricted workload security contexts and opt-in egress policies in the amd64 integration environment before making egress isolation a default.
5. Add optional public routes for additional Pulp plugins only when their route and authentication contracts are covered by tests.

## Implemented, pending integration proof

- One-shot, maintenance-gated recovery Jobs produce encrypted Restic snapshots
  of all three databases, Pulp filesystem storage, and application Secrets.
- Restore requires an explicit confirmation value, validates snapshot identity
  and contents before deletion, and keeps recovery RBAC separate from runtime
  ServiceAccounts.
- PostgreSQL servers, database roles, Restic storage, repository credentials,
  and infrastructure-level backups remain external ownership boundaries.
- Normal workloads now run with explicit non-root identities, dropped
  capabilities, runtime-default seccomp, and no Kubernetes API token. Egress
  isolation is implemented but remains opt-in until deployment-specific
  PostgreSQL, Valkey, proxy, and repository destinations are supplied.
- Startup and liveness checks are isolated from dependency-aware readiness,
  and disruption budgets are emitted only for genuinely redundant workloads.

## Candlepin HA track

Implemented in the chart, pending amd64 integration proof:

- external Artemis URL and optional TLS material come from Secrets;
- embedded Artemis is disabled in HA mode;
- Quartz JDBC clustering uses a common name and automatic unique instance IDs;
- a dedicated Liquibase Job owns database changes while application pods use
  `HALT`;
- replicas greater than one require the full HA and migration contract;
- topology spread and a disruption budget protect redundant pods.

Still required:

1. Prove one-time Artemis job delivery and reconnect behavior.
2. Run the prepared Quartz membership and stale-instance failover assertion on
   amd64; the harness now terminates one scheduler pod and requires a distinct
   replacement while retaining exactly two live cluster rows.
3. Exercise failed and successful migrations against the pinned image set.
4. Move migration-before-rollout sequencing into the operator, then replace
   `Recreate` with a proven rolling strategy.

## Operator track

After the Helm lifecycle and runtime contracts are proven, add a small Go operator that:

- validates compatible Foreman/Katello/Candlepin/Pulp version sets;
- creates migration Jobs and waits for their completion before rolling workloads;
- reports component health in a custom resource status;
- performs controlled upgrades and rollback gating;
- manages Smart Proxy registration without taking ownership of edge DHCP/DNS networks.
