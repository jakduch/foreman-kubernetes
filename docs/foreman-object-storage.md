# Foreman object storage

Foreman uses Active Storage for plugin-owned blobs. The chart keeps `local` as
the package-compatible default and can select AWS S3 or an S3-compatible
service such as MinIO or Ceph RGW:

```yaml
foreman:
  activeStorage:
    service: s3
    s3:
      bucket: foreman-active-storage
      region: us-east-1
      endpoint: https://object-storage.example.test
      forcePathStyle: true
      existingSecret: foreman-object-storage
      existingCaSecret: foreman-object-storage-ca
```

Apply [`examples/foreman-s3-values.yaml`](../examples/foreman-s3-values.yaml)
after the base environment values. `endpoint` and `forcePathStyle: true` are
normally required for MinIO, Ceph RGW, and other path-style implementations.
Leave `endpoint` empty for AWS S3.

## Credentials and trust

Prefer workload identity and leave `existingSecret` empty when the cluster
supplies an AWS-compatible credential chain to the Foreman service account.
Otherwise, create the named Secret with the selected keys:

```yaml
stringData:
  access-key-id: CHANGE_ME
  secret-access-key: CHANGE_ME
```

Credentials are injected into every Foreman web, Dynflow, migration, recurring,
registration, dependency-check, and Helm-test process. They are never rendered
into a ConfigMap or committed values file.

For a private HTTPS trust root, set `existingCaSecret`. The selected key is
mounted read-only and exposed through `AWS_CA_BUNDLE`, which the AWS Ruby SDK
uses for endpoint verification. Do not disable TLS verification.

When egress NetworkPolicy is enabled, identify the object-storage route through
`networkPolicy.egress.external.foreman` or enable the shared outbound proxy.
The chart rejects an S3 profile that would be isolated from its endpoint.

## Validation and compatibility

The dependency preflight lists the bucket before migrations. After the release
is ready, `helm test` creates a multipart-sized Active Storage blob through
Rails, downloads it byte-for-byte, checks its recorded size, and purges it.
This validates the same configuration and credentials used by web and Dynflow
pods rather than testing the S3 API independently of Foreman.

The profile requires the upstream Foreman Active Storage foundation and S3
configuration work plus plugin migrations that move shared files into Active
Storage. Until those changes ship in a compatible Foreman image, keep this
profile disabled. The chart intentionally retains the Foreman shared-tmp and
avatar RWX claims in this change; removing them before Katello uploads, LDAP
avatars, and `foreman_rh_cloud` reports use object storage would lose data or
break cross-pod jobs.

Object-store backup is an external consistency boundary. Record and test an
exact provider recovery point together with the PostgreSQL snapshot before
claiming disaster-recovery coverage for an S3-backed release.
