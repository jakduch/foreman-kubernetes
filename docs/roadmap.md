# Roadmap

## Next vertical slice

1. Add upgrade smoke tests using disposable PostgreSQL, Valkey, and RWX-compatible storage in a local Kubernetes cluster.
2. Add backup and restore Jobs for all three databases, Pulp content, PKI, and configuration Secrets.
3. Complete the remaining workload security contexts, disruption budgets, and narrowly scoped egress policies.
4. Add optional public routes for additional Pulp plugins only when their route and authentication contracts are covered by tests.

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
