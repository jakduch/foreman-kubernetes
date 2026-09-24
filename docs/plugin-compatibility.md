# Plugin compatibility and placement

Compatibility is tracked against the plugins packaged in the official Foreman,
Pulp, and Foreman Proxy images. This is narrower than every community plugin in
the Foreman ecosystem. A community plugin first needs a reproducible image build
before this chart can make a runtime compatibility claim.

The machine-readable inventory is
[`compatibility/plugin-matrix.json`](../compatibility/plugin-matrix.json). Its
states deliberately distinguish four different facts:

1. the package exists in an image;
2. the application can load it and run its migrations;
3. external services, credentials, routes, persistence, and egress are modelled;
4. its real workflow passed the amd64 integration suite.

Only `foreman-tasks` and `katello` are enabled by default. They are wired into
the chart, but remain labelled `integration-pending` until the full install and
content lifecycle test passes. Other packaged Rails plugins require
`foreman.pluginPolicy.allowUnverified=true`; this is an explicit test escape
hatch, not a support claim. The schema rejects plugin names that are absent
from the reviewed official image.

## Foreman image

| Plugin | Default | Placement | Missing proof or contract |
| --- | --- | --- | --- |
| `foreman-tasks` | yes | Foreman and Dynflow pods | full integration run |
| `katello` | yes | Foreman pods | full Katello content lifecycle |
| `foreman_remote_execution` | no | Foreman plus an execution Smart Proxy | proxy lifecycle, keys, callbacks, HA |
| `foreman_ansible` | no | Foreman plus an Ansible/REX Smart Proxy | role storage, runner artifacts, proxy lifecycle |
| `foreman_google` | no | Foreman pods | provider credentials, egress, API test |
| `foreman_azure_rm` | no | Foreman pods | provider credentials, egress, API test |
| `foreman_kubevirt` | no | Foreman pods | KubeVirt credentials, egress, API test |
| `foreman_rh_cloud` | no | Foreman pods | cloud credentials, egress, service workflow |
| `foreman_webhooks` | no | Foreman pods | destination allow-list and delivery/retry test |
| `foreman_virt_who_configure` | no | Foreman plus external virt-who | external service lifecycle |

The base image also installs compute-provider packages for libvirt, VMware,
OpenStack, and EC2. These are not selected through `FOREMAN_ENABLED_PLUGINS`;
each still needs provider-specific credential, egress, and lifecycle tests.

## Pulp image

The reviewed image contains `pulp_ansible`, `pulp_container`, `pulp_deb`,
`pulp_ostree`, `pulp_python`, `pulp_rpm`, and `pulp_smart_proxy`; Pulpcore also
provides the file and content-guard applications used by this chart. The schema
accepts only that inventory and always requires `pulp_certguard`, `pulp_file`,
and `pulp_smart_proxy` because Katello's control and registration path depends
on them.

The default enables container, Debian, file, and RPM content. Ansible, OSTree,
and Python remain disabled until each public route and real content lifecycle
is tested. A package being present in the image is not sufficient evidence that
the ingress and Katello integration are correct.

## Smart Proxy placement

There is no single mandatory Smart Proxy machine. Foreman supports multiple
proxies, and each should be placed close to the resources it controls.

| Function | Placement in this design | Reason |
| --- | --- | --- |
| Pulp content | Pulp control endpoint in Kubernetes | implemented as Pulp's `pulp_smart_proxy`, not a generic Smart Proxy pod |
| Remote Execution / Ansible | future dedicated execution proxy; Kubernetes or edge | can run centrally only when target reachability, keys, artifacts, callbacks, and failure semantics are proven |
| DHCP / DNS / TFTP | external edge proxy | tied to provisioning networks, stable endpoints, backend state, and often privileged host integration |
| BMC / Redfish | external management-network proxy | must reach the isolated management network and handle privileged credentials |
| Discovery | external provisioning-network proxy | requires direct placement on the discovery/PXE network |
| Puppet/OpenVox CA | external dedicated proxy | owns CA and configuration-management state |
| OpenSCAP | external or dedicated proxy | owns report/content paths and client-facing connectivity |
| Templates / Registration | direct Foreman ingress unless an edge content proxy is required | no reason to add a central generic proxy merely because older all-in-one installations co-located it |

`smartProxy.mode` is currently fixed to `external`. The chart does not create a
generic Smart Proxy container, does not expose DHCP/DNS/TFTP service ports, and
does not grant host networking, privileged mode, or Linux capabilities to an
application pod. Consequently those services cannot be enabled through this
chart on the Foreman web Deployment.

A future central-execution chart must use a positive feature allow-list rather
than accepting arbitrary `settings.d` files. It must also fail readiness if
`/v2/features` advertises DHCP, DNS, TFTP, BMC, Realm, Discovery, Puppet, or
OpenSCAP. NetworkPolicy and the container security context are secondary
controls; the primary control is that the forbidden modules are never rendered
or configured.

## Promotion test

A plugin can move from `integration-pending` to supported only when its profile
proves:

- image package and dependency versions;
- migrations on a fresh database and during an upgrade;
- required Secrets, storage, routes, and egress;
- one successful real workflow and its observable failure path;
- restart and scale behavior for every component it adds;
- backup and restore of any new state.

The official plugin overview remains the discovery source for plugins outside
the current OCI images: <https://theforeman.org/plugins/>.
