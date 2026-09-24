# Central execution Smart Proxy

`charts/foreman-execution-proxy` is a separate Smart Proxy deployment for the
Foreman Remote Execution and Ansible control plane. It is not part of the
Foreman web Deployment and it is not an edge provisioning proxy.

## Feature boundary

The profile loads only the image plugins `remote_execution_ssh` and `ansible`.
Their packaged dependency provides Dynflow, so the only advertised Smart Proxy
features must be:

- `script` (the Remote Execution SSH provider);
- `ansible`;
- `dynflow`.

The image also contains `container_gateway`, while the base Smart Proxy package
contains network-oriented modules. They are not loaded or enabled. The
readiness probe calls the local mTLS `/features` endpoint and requires the
running feature set to equal those three names exactly. A Pod advertising DHCP,
DNS, TFTP, BMC, Realm, Discovery, Puppet/OpenVox, OpenSCAP, logs, registration,
templates, container gateway, or any future accidental feature stays out of
Service endpoints.

The Deployment has no host network, host PID/IPC namespace, Kubernetes API
token, privileged mode, or Linux capabilities. Its Service is `ClusterIP` only.
Edge DHCP/DNS/TFTP and isolated management networks remain the responsibility
of separately registered Smart Proxies placed near those networks.

## Current scale and state contract

The replica count is fixed to one. This is intentional, not a missing HPA:

- Smart Proxy Dynflow defaults to memory-only persistence, so the chart points
  it at a SQLite database on the state claim;
- REx also keeps some SSH job data in the process;
- Ansible runner artifacts and SSH control sockets are local to the executor;
- two replicas behind one Service would not provide ownership or handoff for an
  already dispatched job.

The state PVC contains the Dynflow database plus REx and Ansible runner working
directories. `Recreate` prevents two pods from owning it during a rollout. A
restart can retain the Dynflow plan and runner files, but site-loss recovery of
an in-flight command is not yet claimed. Treat Foreman as the job source of
truth and retry interrupted jobs after validating their target-side effects.

Ansible roles, collections, and `ansible.cfg` live on a separate claim mounted
read-only at `/etc/ansible`. Prefer a reviewed Git/Ansible Galaxy pipeline that
publishes immutable content to that claim. Every selectable execution proxy
must receive the same role and collection versions; importing role metadata in
Foreman does not distribute role content to executors.

## Required identity material

The chart consumes existing Secrets and never generates private keys:

| Value | Required keys by default | Purpose |
| --- | --- | --- |
| `proxy.existingTlsSecret` | `ca.crt`, `tls.crt`, `tls.key` | HTTPS server identity and trusted client CA |
| `proxy.existingForemanClientSecret` | `ca.crt`, `tls.crt`, `tls.key` | mTLS client identity for callbacks to Foreman |
| `ssh.existingKeySecret` | `id_rsa_foreman_proxy`, `id_rsa_foreman_proxy.pub` | authentication to managed hosts and public-key publication |
| `ssh.hostKeyVerification.existingKnownHostsSecret` | `known_hosts` | optional pinned host keys or `@cert-authority` records |

Secret key names are configurable. The SSH key projection is group-readable
only long enough for a non-root init container to copy it into an `emptyDir`
with mode `0600`; the main container receives that runtime copy read-only.

SSH user certificates are supported by enabling `ssh.userCertificate` and
adding the configured certificate and CA public-key entries to the SSH Secret.
Strict target host-key checking is opt-in because the existing foremanctl
container profile disables it. When enabled here, the same known-hosts/SSH-CA
file is applied to both Remote Execution and Ansible.

The HTTPS certificate must contain the cluster Service DNS name used when the
proxy is registered, for example:

```text
execution-foreman-execution-proxy.foreman.svc
```

Its client CA must trust the certificate Foreman presents to Smart Proxy. The
common name from that Foreman certificate must be present in
`proxy.trustedHosts`.

## Install and register

First enable the matching Rails plugins in the application release. The
provided overlay preserves the default Katello plugins and adds Remote
Execution plus Ansible:

```sh
helm upgrade --install foreman charts/foreman-stack \
  --namespace foreman \
  --values examples/cluster-values.yaml \
  --values examples/execution-control-plane-values.yaml
```

Create the proxy Secrets and content/state claims, then render or install the
separate execution release:

```sh
helm lint charts/foreman-execution-proxy \
  --values examples/execution-proxy-values.yaml
helm upgrade --install execution charts/foreman-execution-proxy \
  --namespace foreman \
  --values examples/execution-proxy-values.yaml
```

Register the Service URL in Foreman through Infrastructure > Smart Proxies or
with Hammer, then refresh its features. Automatic registration is deliberately
absent: a Helm workload should not retain Foreman administrator credentials,
and proxy OAuth/bootstrap ownership belongs to the future operator.

Before assigning the proxy to hosts, verify that Foreman shows only **Ansible**,
**Dynflow**, and **Script**, imports the expected role versions, and can execute
one harmless command plus one Ansible role against a disposable target.

## Network isolation

Ingress is limited by default to Foreman and Dynflow-labelled pods belonging to
the `foreman` Helm release in the same namespace. Override the ingress peers
when the application release has another name. Egress isolation is opt-in
because Kubernetes NetworkPolicy cannot translate `proxy.foremanUrl` or
managed-host names to addresses. Enabling it requires both:

- explicit Foreman peers and callback ports;
- explicit managed-host peers and every allowed SSH port.

The chart rejects an egress-restricted render when either peer set is empty.
The example profile shows the Foreman ingress address on HTTPS and a target
CIDR. The allowed Foreman peer must describe the address actually resolved by
`proxy.foremanUrl`; it is not necessarily the Foreman Pod address. Do not use
`0.0.0.0/0` merely to make jobs pass; model the actual management networks.

## Proof status

Static Helm, schema, relationship, security-context, and negative feature
boundary tests are implemented. Still required before production support:

1. run the pinned amd64 image and verify its exact packaged feature list;
2. execute SSH and Ansible jobs, including cancellation and a Pod restart;
3. verify role/collection refresh and SSH key or certificate rotation;
4. validate restricted egress against real Foreman and target networks;
5. test upgrade and recovery with an active and an interrupted job.
