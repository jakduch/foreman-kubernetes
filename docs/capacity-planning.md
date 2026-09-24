# Capacity planning

The chart does not own PostgreSQL, Valkey, or an object store. Their capacity
must therefore be sized from the largest allowed application topology, not only
from the initial replica count.

## Foreman PostgreSQL connections

Every Puma worker and every Rails background process owns a separate Active
Record connection pool. The chart mounts an explicit `database.yml` and assigns
the following pools rather than inheriting Foreman's fixed upstream default:

| Process | Pool value | Required lower bound |
| --- | ---: | ---: |
| one Puma worker | `foreman.databasePools.web` | `foreman.puma.threadsMax` |
| one general Dynflow worker | `foreman.databasePools.dynflowWorker` | `foreman.dynflow.workerConcurrency` |
| one hosts-queue worker | `foreman.databasePools.dynflowHostsQueue` | `foreman.dynflow.hostsQueueConcurrency` |
| orchestrator, event daemon, or one-shot Job | `foreman.databasePools.utility` | 1 |

For the hard ceiling, use the HPA maximum when autoscaling is enabled:

```text
web = web_max_replicas * puma_workers * web_pool
background = dynflow_workers * dynflow_worker_pool
           + hosts_queue_workers * hosts_queue_pool
           + 2 * utility_pool
steady_state_foreman = web + background
```

During a Helm revision, Foreman web, general Dynflow, and hosts-queue Dynflow
Deployments can each add one surge Pod. Reserve an additional
`puma_workers * web_pool + dynflow_worker_pool + hosts_queue_pool` connections
for the worst case in which those rollouts overlap. The Helm notes report both
steady-state and rolling-update ceilings.

The two fixed utility processes are the Dynflow orchestrator and Katello event
daemon. Add one utility pool for every migration, Pulp-registration, or
recurring-task Job that may overlap. Pools are lazy ceilings, not a promise
that every connection is open continuously, but PostgreSQL and any PgBouncer
layer must be able to absorb the declared concurrency without starvation.

The Helm post-install notes calculate this Foreman ceiling from the rendered
profile. Reducing a pool below Puma or Sidekiq concurrency is rejected because
it can starve application threads while they wait for database connections.

## Other databases

Candlepin's upstream Hibernate configuration permits 20 connections per
replica. Its clustered Quartz data source adds up to 5 more connections per
replica. Reserve migration connections on top of that during upgrades.

Pulp API and content replicas contain the configured number of Gunicorn worker
processes, while each Pulp worker is a database-backed task executor. Exact
connection reuse depends on the Pulpcore/Django versions in the selected image,
so size Pulp PostgreSQL from observed saturation in the full integration
environment and retain headroom for migrations and task bursts. Do not infer a
safe production maximum from the chart's development defaults alone.

## Valkey roles

`valkey.foremanCache`, `valkey.dynflow`, and `valkey.pulp` are independent
endpoint contracts. They can share one host in a development environment, but
their production failure and eviction semantics differ:

- Foreman cache data is disposable and may use a bounded cache policy.
- Dynflow carries the Sidekiq transport and singleton lock. Give it durable
  storage, failover, sufficient client connections for every Foreman and
  Dynflow process, and `maxmemory-policy noeviction`.
- Pulp uses Valkey for its cache and must retain enough connections for every
  API, content, worker, and migration process.

All three production endpoints use authenticated `rediss` URLs and verify the
configured private CA. Monitor memory, rejected connections, evictions, and
failover latency; an eviction count above zero on Dynflow is a correctness
incident rather than an ordinary cache-capacity signal.

## CPU autoscaling and node capacity

Resource-based HPAs require a healthy `v1beta1.metrics.k8s.io` APIService. The
guarded install and upgrade scripts verify it before changing a release. The
production example also makes topology spread hard: if the cluster cannot
place the minimum replicas on distinct nodes, workloads remain Pending rather
than silently giving up the requested failure separation.
