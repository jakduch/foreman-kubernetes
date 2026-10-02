# Orchestration and ownership boundary

This document records the initial design decisions that distinguish Kubernetes
packaging from changes that belong in Foreman, Katello, Candlepin, Pulp,
Smart Proxy, or `foremanctl`.

## One compatible stack, distinct workloads

Foreman with Katello, Candlepin, and Pulp is installed and upgraded as one
tested compatibility set. "Separate" means that a component keeps its upstream
image, process model, service, scaling policy, and failure boundary. It does not
mean that arbitrary versions of the components are independently supported or
that Katello becomes a standalone service outside Foreman.

The Kubernetes project publishes no replacement Foreman, Candlepin, or Pulp
images. Local candidate images are test artifacts for unpublished upstream
commits and cannot be promoted as project releases.

## Generic capabilities versus Kubernetes orchestration

External PostgreSQL, Valkey, object storage, TLS configuration, foreground
processes, and explicit migration commands are generic container runtime
capabilities. They can benefit `foremanctl` and other supervisors as well as
Kubernetes. Their application behavior and defaults belong upstream.

This repository owns only their Kubernetes consumption: typed values,
Secrets, Services, Jobs, probes, NetworkPolicies, scheduling, release ordering,
and qualification. Requiring externally managed stateful services is an
initial chart boundary, not a claim that only Kubernetes needs those services.

## Why Helm and an operator

Helm is the packaging and rendering interface. It provides inspectable
manifests, values schemas, a conventional manual installation path, and a
reusable substrate for other lifecycle tools.

The optional `ForemanRelease` operator does not replace those charts. It owns
stateful lifecycle decisions that a normal Helm invocation cannot safely infer:

- validating an exact digest-pinned compatibility set and external inputs;
- fencing concurrent writers;
- running dependency checks and schema migrations before workload changes;
- checkpointing progress across controller restarts;
- applying the application and execution-proxy releases in order;
- stopping after an irreversible migration failure instead of rolling back
  application manifests across a changed schema;
- verifying the resulting release and repairing safe stateless drift.

Keeping rendering and lifecycle separate allows the community to review Helm
versus controller responsibilities independently. A future operator API may
change without moving application source or runtime configuration into the
controller.

## Database migrations

"Separate and observable migrations" means one finite Job for each schema
owner: Candlepin, Pulp, and Foreman/Katello. The Jobs use the same image and
configuration contract as the corresponding runtime, have explicit deadlines,
and finish before new application workloads are submitted. Their status and
logs remain observable independently of a long-running Deployment.

This is release sequencing, not a Kubernetes-specific application mode. The
underlying migration entry points should also be usable by `foremanctl` or any
other supervisor.

## Candlepin and Katello events

The initial chart runs Candlepin as a singleton and does not operate an external
broker. Candlepin's internal messaging implementation is not part of the
Kubernetes API or values contract. Horizontal Candlepin scaling remains out of
scope until a current upstream contract is reviewed and tested.

The chart does not run a separate Katello event-daemon Deployment and does not
carry a Kubernetes-specific Katello runner patch. Event handling remains an
upstream Katello implementation detail instead of becoming another platform
workload owned here.

## Smart Proxy placement

The central application stack talks to both on-cluster and off-cluster Smart
Proxies through the normal Foreman registration and feature-discovery
interfaces.

The supplied on-cluster profile is deliberately narrow: a singleton execution
proxy for Remote Execution SSH and Ansible. DHCP, DNS, TFTP, BMC, and other
network-local features remain on separately operated proxies near the networks
they manage. Additional on-cluster profiles can be added when their state,
privilege, networking, and lifecycle contracts are explicit; generic proxy
features are never embedded in Foreman web pods.

## Relationship to foremanctl

`foremanctl` and this project are two orchestrators for the same published
application images and generic runtime contracts. Node operating-system
independence comes from container images in both models; it is not novel to
Kubernetes. Kubernetes adds cluster scheduling, Services, policy, controllers,
and workload-level scaling, while `foremanctl` integrates containers with
Podman, systemd, and host lifecycle.

Compatible image sets, health semantics, migration ordering, certificate
handling, and generic functional validation should converge where practical.
Neither project should introduce an incompatible application mode merely to
satisfy its own supervisor.
