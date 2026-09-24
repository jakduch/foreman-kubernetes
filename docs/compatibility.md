# Image compatibility sets

The chart keeps component ownership separate and does not assume that independently published moving tags are compatible. A profile pins one candidate combination by OCI digest. Promotion to a supported set requires the disposable install, mTLS registration, scale, and upgrade test to pass.

## Nightly candidate from 2026-09-23

| Component | Published tag | OCI digest | Platform | Status |
| --- | --- | --- | --- | --- |
| Foreman with Katello | `quay.io/foreman/foreman:nightly` | `sha256:9c77128c7acd629c62686a9119816d6f6b7726cd6492d9eaa894d54c345c4941` | `linux/amd64` | Manifest verified; integration pending |
| Candlepin | `quay.io/foreman/candlepin:foreman-nightly` | `sha256:b9fe6c5f161132b39982e1951e8b4a16bf00d2565ecb17e53b13b56196a1f280` | `linux/amd64` | Manifest verified; integration pending |
| Pulp | `quay.io/foreman/pulp:foreman-nightly` | `sha256:c3d32a385d09225c40f70d60128fcf62c94cb669536b10ccbadc0ec8ac4afa6b` | `linux/amd64` | Manifest verified; integration pending |
| Execution Smart Proxy | `quay.io/foreman/foreman-proxy:nightly` | `sha256:244c756844a137990779ad153998c426eb0326d8d6f376192ea6e84947affd47` | `linux/amd64` | Manifest verified; execution drill implemented but unrun |

The manifests were read from the official Quay repositories on 2026-09-24. No layers were downloaded. The current images are single-platform, so an ARM cluster needs explicit emulation and is not a release target until upstream publishes multi-architecture manifests.

The disposable HA integration test additionally pins
`apache/artemis:2.57.0-alpine` to its verified `linux/amd64` manifest digest
`sha256:ca99ce1b72c5765a15dd507db4215591c43da623cd9f42db1bcd4319e5f4b579`.
It is a test dependency rather than part of the supported application image
set, and the full integration run is still pending.

The execution contract was reviewed against Foreman Remote Execution commit
`be391fd9ef3140df707eed4f320ce2ebd572648d` and Foreman Ansible commit
`7ffc9e37344011554347ca9429fffdcf1f81816e`. These are source snapshots for
contract review, not container provenance claims. The disposable SSH target
uses the verified Alpine 3.22 amd64 manifest
`sha256:3e9b4b680bfc9fb5269227cffbd6d42be39fbf7c0b908123913864aa4447e764`.

Use the candidate with another values file, keeping environment-specific values later so they win:

```sh
helm upgrade --install foreman charts/foreman-stack \
  --values profiles/nightly-candidate-2026-09-23.yaml \
  --values /secure/path/production-values.yaml
```
