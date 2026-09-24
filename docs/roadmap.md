# Roadmap

## Next vertical slice

1. Generate validated Foreman, Katello, Candlepin, Tomcat, Dynflow, and Pulp configuration from a typed values model instead of importing file-bearing Secrets.
2. Add an ingress profile that preserves client-certificate headers and separates the Foreman UI/API route from Pulp content routes.
3. Add upgrade smoke tests using disposable PostgreSQL, Valkey, and RWX-compatible storage in a local Kubernetes cluster.
4. Add backup and restore Jobs for all three databases, Pulp content, PKI, and configuration Secrets.
5. Add NetworkPolicies, security contexts, PodDisruptionBudgets, and topology constraints per component.

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
