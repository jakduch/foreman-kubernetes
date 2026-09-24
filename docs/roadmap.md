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

1. Configure a shared external Artemis broker.
2. Enable and test Quartz JDBC clustering with stable per-pod instance IDs.
3. Separate database migration ownership from normal application startup.
4. Prove job delivery, scheduler failover, and rolling upgrade behavior.
5. Only then remove the schema limit of one Candlepin replica.

## Operator track

After the Helm lifecycle and runtime contracts are proven, add a small Go operator that:

- validates compatible Foreman/Katello/Candlepin/Pulp version sets;
- creates migration Jobs and waits for their completion before rolling workloads;
- reports component health in a custom resource status;
- performs controlled upgrades and rollback gating;
- manages Smart Proxy registration without taking ownership of edge DHCP/DNS networks.
