#!/bin/sh

set -eu
# shellcheck source=recovery-common.sh
. /opt/foreman-recovery/recovery-common.sh

for command in jq kubectl pg_dump restic; do
  require_command "${command}"
done

wait_for_quiescence
prepare_work_directory
dump_databases

log "Exporting application Secrets to the encrypted recovery set"
for secret_name in ${BACKUP_SECRET_NAMES}; do
  kubectl get secret \
    --namespace "${POD_NAMESPACE}" \
    "${secret_name}" \
    --output json |
    jq '{
      apiVersion,
      kind,
      metadata: {name: .metadata.name},
      type,
      data,
      immutable
    } | del(.immutable | nulls)' \
      > "/work/secrets/${secret_name}.json"
done

jq -n \
  --arg schema_version "1" \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg chart_version "${CHART_VERSION}" \
  --arg release "${HELM_RELEASE}" \
  --arg namespace "${POD_NAMESPACE}" \
  --arg secret_names "${BACKUP_SECRET_NAMES}" \
  '{
    schema_version: $schema_version,
    created_at: $created_at,
    chart_version: $chart_version,
    helm_release: $release,
    namespace: $namespace,
    databases: ["foreman", "candlepin", "pulp"],
    includes_pulp_filesystem: true,
    secret_names: ($secret_names | split(" ") | map(select(length > 0)))
  }' > /work/metadata/manifest.json

if ! restic cat config >/dev/null 2>&1; then
  if [ "${INITIALIZE_REPOSITORY}" != true ]; then
    log "Restic repository is unavailable or uninitialized; set backup.initializeRepository=true only for its first use" >&2
    exit 1
  fi
  log "Initializing Restic repository"
  restic init
fi

log "Creating encrypted recovery snapshot"
restic backup \
  --host "${HELM_RELEASE}" \
  --tag foreman-stack \
  --tag "request-${BACKUP_REQUEST_ID}" \
  /work /var/lib/pulp

if [ "${RETENTION_ENABLED}" = true ]; then
  set -- \
    --host "${HELM_RELEASE}" \
    --tag foreman-stack \
    --keep-daily "${RETENTION_KEEP_DAILY}" \
    --keep-weekly "${RETENTION_KEEP_WEEKLY}" \
    --keep-monthly "${RETENTION_KEEP_MONTHLY}"
  if [ "${RETENTION_PRUNE}" = true ]; then
    set -- "$@" --prune
  fi
  log "Applying Restic retention policy"
  restic forget "$@"
fi

log "Recovery snapshot completed"
