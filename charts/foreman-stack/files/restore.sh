#!/bin/sh

set -eu
# shellcheck source=recovery-common.sh
. /opt/foreman-recovery/recovery-common.sh

for command in jq kubectl pg_restore restic; do
  require_command "${command}"
done

if [ "${RESTORE_CONFIRMATION}" != RESTORE ]; then
  log "Restore confirmation is missing" >&2
  exit 1
fi

wait_for_quiescence
prepare_work_directory

snapshot_id="$(resolve_snapshot)"
log "Validated recovery snapshot ${snapshot_id}"

restic restore "${snapshot_id}" \
  --target / \
  --include '/work/**'

for required_file in \
  /work/metadata/manifest.json \
  /work/databases/foreman.dump \
  /work/databases/candlepin.dump \
  /work/databases/pulp.dump; do
  if [ ! -s "${required_file}" ]; then
    log "Recovery snapshot is incomplete: ${required_file} is missing" >&2
    exit 1
  fi
done

jq -e \
  --arg release "${HELM_RELEASE}" \
  --arg namespace "${POD_NAMESPACE}" \
  '.schema_version == "1" and .helm_release == $release and .namespace == $namespace' \
  /work/metadata/manifest.json >/dev/null

log "Replacing Pulp filesystem from the selected recovery snapshot"
find /var/lib/pulp -mindepth 1 -maxdepth 1 -exec rm -rf {} +
restic restore "${snapshot_id}" \
  --target / \
  --include '/var/lib/pulp/**'

restore_database Foreman /work/databases/foreman.dump \
  --dbname "${FOREMAN_DATABASE_URL}"

PGPASSWORD="${CANDLEPIN_DATABASE_PASSWORD}" \
PGSSLMODE="${CANDLEPIN_DATABASE_SSLMODE}" \
PGSSLROOTCERT="${CANDLEPIN_DATABASE_SSLROOTCERT:-}" \
  restore_database Candlepin /work/databases/candlepin.dump \
    --host "${CANDLEPIN_DATABASE_HOST}" \
    --port "${CANDLEPIN_DATABASE_PORT}" \
    --username "${CANDLEPIN_DATABASE_USER}" \
    --dbname "${CANDLEPIN_DATABASE_NAME}"

PGPASSWORD="${PULP_DATABASE_PASSWORD}" \
PGSSLMODE="${PULP_DATABASE_SSLMODE}" \
PGSSLROOTCERT="${PULP_DATABASE_SSLROOTCERT:-}" \
  restore_database Pulp /work/databases/pulp.dump \
    --host "${PULP_DATABASE_HOST}" \
    --port "${PULP_DATABASE_PORT}" \
    --username "${PULP_DATABASE_USER}" \
    --dbname "${PULP_DATABASE_NAME}"

if [ "${RESTORE_SECRETS}" = true ]; then
  log "Restoring application Secrets"
  for secret_name in ${BACKUP_SECRET_NAMES}; do
    secret_file="/work/secrets/${secret_name}.json"
    if [ ! -s "${secret_file}" ]; then
      log "Secret escrow is incomplete: ${secret_name} is missing" >&2
      exit 1
    fi
    kubectl apply \
      --namespace "${POD_NAMESPACE}" \
      --server-side \
      --force-conflicts \
      --field-manager foreman-stack-recovery \
      --filename "${secret_file}"
  done
else
  log "Secret escrow was not applied; restore required application encryption and signing keys before leaving maintenance mode"
fi

log "Restore completed; leave maintenance mode to run migrations and restart workloads"
