# Disaster recovery

The chart provides explicit, one-shot backup and restore Jobs. They create an
application-consistent recovery point only while maintenance mode has removed
all workloads that can write to Foreman, Candlepin, or Pulp state.

Quiescence includes Pods that are still terminating: a deletion timestamp does
not prove that a process has stopped writing. Completed and failed Job Pods are
ignored because their processes have already exited.

The recovery set contains:

- logical, custom-format PostgreSQL dumps for Foreman, Candlepin, and Pulp;
- Foreman's LDAP avatar files, whose hashes but not bytes live in PostgreSQL;
- the complete Pulp filesystem mounted at `/var/lib/pulp` when filesystem
  storage is selected;
- an encrypted escrow copy of the application, certificate, ingress, and image
  pull Secrets known to the chart;
- a versioned manifest identifying the Helm release, namespace, chart, and
  exact digest-pinned compatibility set.

Valkey is deliberately excluded. It contains cache and task transport state,
not the authoritative application records. Any work that was in flight when a
recovery point was taken must be reconciled after the restore.

## Boundaries

The chart does not own PostgreSQL servers, database roles, the Restic storage
backend, or its credentials. Production database physical backups, WAL
archiving, bucket replication, and storage snapshots remain the responsibility
of their respective operators. The Jobs provide a portable application-level
recovery set; they do not replace those infrastructure controls.

The repository credentials are intentionally not included in their own backup.
Escrow the repository Secret and its password outside the cluster. A local
Restic repository must use storage independent from the Pulp data claim or it
will not survive the same storage failure.

With Pulp object storage, the recovery set records the backend and excludes
bucket objects. Protect the bucket independently with versioning or provider
snapshots and replication. Coordinate its recovery point with the database
dump; the chart refuses to restore a snapshot created for a different Pulp
storage backend.

For S3 restores, roll the bucket back first and add
`--set restore.objectStorageConfirmation=BUCKET_RESTORED` to the restore Helm
revision. Both the schema and the recovery script reject the database restore
without this separate acknowledgement.

## Recovery toolbox

The `Recovery toolbox image` workflow builds only `linux/amd64`, executes every
command used by the recovery scripts, and publishes the image to GHCR with an
SBOM and build provenance. Push a `recovery-v*` tag for a versioned image or
dispatch the workflow for a commit-tagged qualification build. Copy the
immutable `repository@sha256:...` reference from its job summary.

For another registry, build and publish the same pinned Dockerfile before
enabling either Job:

```sh
docker build \
  --file Dockerfile \
  --tag registry.example.test/foreman-kubernetes-recovery-toolbox:0.1.0 \
  images/recovery-toolbox
docker push registry.example.test/foreman-kubernetes-recovery-toolbox:0.1.0
```

Set `recovery.image.repository` to the registry path and
`recovery.image.tag` to `version@sha256:digest`; the digest, rather than the
human-readable tag, is the deployment identity. The image contains only the
PostgreSQL client, Restic, `kubectl`, `jq`, and their runtime dependencies; the
versioned workflow scripts are mounted from the chart.

## Repository Secret

For a remote Restic repository, create a Secret containing
`RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, and the backend-specific credentials.
The guarded install and upgrade helpers validate the first two keys before
making a release change. A repository mounted from a PVC needs only
`RESTIC_PASSWORD`; its path is supplied by the chart.
For example, an S3-compatible target can use:

```sh
kubectl --namespace foreman create secret generic foreman-backup-repository \
  --from-literal=RESTIC_REPOSITORY='s3:https://s3.example.test/foreman-backups' \
  --from-literal=RESTIC_PASSWORD='replace-me' \
  --from-literal=AWS_ACCESS_KEY_ID='replace-me' \
  --from-literal=AWS_SECRET_ACCESS_KEY='replace-me'
```

For a local Restic repository, put only `RESTIC_PASSWORD` in the Secret and set
`recovery.repository.existingClaim`. The chart then sets `RESTIC_REPOSITORY` to
`recovery.repository.path` inside that claim.

When restricted egress is enabled, set
`networkPolicy.egress.recovery.apiServer` to the control-plane endpoint used by
the in-cluster Kubernetes Service. A remote repository also requires
`networkPolicy.egress.recovery.repository`; list only the CIDRs and ports used
by that Restic backend (for example TCP 443 for S3 or TCP 22 for SFTP). The
repository rule is not rendered when `recovery.repository.existingClaim` is
set. Helm refuses to create a recovery Job with missing destinations instead
of silently giving this credential-rich Pod unrestricted egress.

Database dumps use an `emptyDir` with `recovery.work.sizeLimit` by default. Set
`recovery.work.existingClaim` when the three compressed dumps may exceed a
node's safe ephemeral-storage allowance.

## Create a recovery point

Every request needs a new lower-case identifier of at most 16 characters. The
first backup to a new repository additionally needs
`backup.initializeRepository=true`; leave it false afterwards.

```sh
INITIALIZE_REPOSITORY=1 \
  scripts/recover-release.sh backup \
    /secure/path/application-values.yaml \
    /secure/path/execution-proxy-values.yaml \
    20260924-120000
```

The helper resolves the same compatibility set as installation and upgrades,
acquires their shared renewable Lease, checks the current application and
execution proxy, and validates every recovery dependency before changing the
release. It then removes the database-writing Deployments and recurring tasks.
The Job independently verifies that their pods are gone before reading any
state. It fails instead of taking an online, potentially inconsistent copy.
After success, the helper restores the normal digest-pinned revision and runs
the application smoke test. A failed Job deliberately leaves maintenance mode
active for inspection.

Retention removes snapshot metadata according to the configured daily, weekly,
and monthly counts. Pruning repository packs is disabled by default because it
can be I/O intensive; enable it in a dedicated maintenance window.

## Restore a recovery point

The target PostgreSQL databases and roles must already exist. Current runtime
Secrets must let the restore Job connect to them. Use `latest` to select the
newest snapshot for this Helm release, or supply a full snapshot ID.

```sh
RESTORE_SNAPSHOT=latest \
  scripts/recover-release.sh restore \
    /secure/path/application-values.yaml \
    /secure/path/execution-proxy-values.yaml \
    20260924-130000
```

The Job validates the snapshot owner, tag, compatibility set, storage backend, manifest, all three
dumps, the avatar tree, the Pulp tree in filesystem mode, and every requested
Secret escrow file before modifying state. It also verifies the paths against
Restic's snapshot inventory, so stale files on a reused work volume cannot make
an incomplete snapshot appear valid. Only after that preflight boundary does it
delete or replace current data. In S3 mode it leaves objects untouched and
requires the operator to restore the bucket to the coordinated point before
leaving maintenance mode. It replaces objects inside the existing databases
but never drops or creates the databases or their roles.

A snapshot must first be restored with the same compatibility set that created
it. Run a normal guarded upgrade only after the restored release is healthy;
this keeps data restoration and application migration as two separately
auditable operations.

Secret escrow is not applied by default. This avoids silently reverting rotated
external database credentials. To restore it in the same environment, add
`--set restore.secrets=true`; all target Secrets must already exist because the
recovery ServiceAccount may patch only the explicitly named Secrets and cannot
create arbitrary ones. If database credentials changed after the snapshot,
reconcile them before restarting the applications.

Set `RESTORE_SECRETS=1` only when the encrypted Secret escrow should be applied.
For S3 mode, set `OBJECT_STORAGE_CONFIRMATION=BUCKET_RESTORED` after restoring
the bucket. A successful restore automatically recreates workloads, runs Pulp
and Foreman migrations, re-registers the private Pulp endpoint, and executes
the smoke test.

After diagnosing a failed backup, restore, or interrupted recovery helper,
leave maintenance mode through the same guarded path:

```sh
scripts/recover-release.sh resume \
  /secure/path/application-values.yaml \
  /secure/path/execution-proxy-values.yaml
```

`ALLOW_CANDIDATE`, `COMPATIBILITY_SET`, the release/namespace overrides, and
the shared `RELEASE_LEASE_*` settings have the same meaning as in the install
and upgrade helpers. `RECOVERY_TIMEOUT`, `RESUME_TIMEOUT`, and `SMOKE_TIMEOUT`
control their respective waits.

## Required recovery drill

A recovery mechanism is not considered verified until a disposable cluster can:

1. create data in Foreman, Candlepin, and Pulp;
2. create a recovery snapshot;
3. replace all three databases, Pulp storage, and application Secrets, using a
   coordinated bucket recovery point in S3 mode;
4. restore the snapshot into a clean namespace;
5. pass Foreman ping, Candlepin status, Pulp content download, and Katello Pulp
   registration checks;
6. run a second Helm revision successfully.

This drill belongs on an amd64 runner because the currently pinned Foreman,
Candlepin, and Pulp images are amd64-only.
