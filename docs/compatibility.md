# Image compatibility sets

The chart keeps component ownership separate and does not assume that independently published moving tags are compatible. A profile pins one candidate combination by OCI digest. Promotion to a supported set requires the disposable install, mTLS registration, scale, and upgrade test to pass.

## Nightly candidate from 2026-09-23

| Component | Published tag | OCI digest | Platform | Status |
| --- | --- | --- | --- | --- |
| Foreman with Katello | `quay.io/foreman/foreman:nightly` | `sha256:9c77128c7acd629c62686a9119816d6f6b7726cd6492d9eaa894d54c345c4941` | `linux/amd64` | Manifest verified; integration pending |
| Candlepin | `quay.io/foreman/candlepin:foreman-nightly` | `sha256:b9fe6c5f161132b39982e1951e8b4a16bf00d2565ecb17e53b13b56196a1f280` | `linux/amd64` | Manifest verified; integration pending |
| Pulp | `quay.io/foreman/pulp:foreman-nightly` | `sha256:c3d32a385d09225c40f70d60128fcf62c94cb669536b10ccbadc0ec8ac4afa6b` | `linux/amd64` | Manifest verified; integration pending |

The manifests were read from the official Quay repositories on 2026-09-24. No layers were downloaded. The current images are single-platform, so an ARM cluster needs explicit emulation and is not a release target until upstream publishes multi-architecture manifests.

Use the candidate with another values file, keeping environment-specific values later so they win:

```sh
helm upgrade --install foreman charts/foreman-stack \
  --values profiles/nightly-candidate-2026-09-23.yaml \
  --values /secure/path/production-values.yaml
```
