#!/bin/sh

set -eu
umask 077

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    log "Required command is unavailable: $1" >&2
    exit 1
  }
}

wait_for_quiescence() {
  started_at="$(date +%s)"

  while :; do
    active_pods="$(
      kubectl get pods --namespace "${POD_NAMESPACE}" \
        --selector "app.kubernetes.io/instance=${HELM_RELEASE}" \
        --output json |
        jq -r '
          .items[]
          | select(
              (.status.phase // "") != "Succeeded" and
              (.status.phase // "") != "Failed"
            )
          | .metadata.labels["app.kubernetes.io/component"] as $component
          | select(
              $component == "foreman" or
              $component == "candlepin" or
              $component == "pulp-api" or
              $component == "pulp-content" or
              $component == "pulp-worker" or
              $component == "katello-event-daemon" or
              $component == "foreman-cron" or
              $component == "foreman-migrate" or
              $component == "pulp-migrate" or
              $component == "pulp-registration" or
              ($component | startswith("dynflow-"))
            )
          | .metadata.name
        '
    )"

    if [ -z "${active_pods}" ]; then
      log "All database-writing workloads are quiescent"
      return
    fi

    now="$(date +%s)"
    if [ "$((now - started_at))" -ge "${QUIESCENCE_TIMEOUT_SECONDS}" ]; then
      log "Timed out waiting for database-writing pods to stop:" >&2
      printf '%s\n' "${active_pods}" >&2
      exit 1
    fi

    log "Waiting for database-writing pods to stop"
    sleep 5
  done
}

prepare_work_directory() {
  find /work -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  mkdir -p /work/databases /work/metadata /work/secrets
}

dump_databases() {
  log "Dumping Foreman database"
  pg_dump \
    --format=custom \
    --no-owner \
    --no-acl \
    --file=/work/databases/foreman.dump \
    "${FOREMAN_DATABASE_URL}"

  log "Dumping Candlepin database"
  PGPASSWORD="${CANDLEPIN_DATABASE_PASSWORD}" \
  PGSSLMODE="${CANDLEPIN_DATABASE_SSLMODE}" \
  PGSSLROOTCERT="${CANDLEPIN_DATABASE_SSLROOTCERT:-}" \
    pg_dump \
      --host "${CANDLEPIN_DATABASE_HOST}" \
      --port "${CANDLEPIN_DATABASE_PORT}" \
      --username "${CANDLEPIN_DATABASE_USER}" \
      --dbname "${CANDLEPIN_DATABASE_NAME}" \
      --format=custom \
      --no-owner \
      --no-acl \
      --file=/work/databases/candlepin.dump

  log "Dumping Pulp database"
  PGPASSWORD="${PULP_DATABASE_PASSWORD}" \
  PGSSLMODE="${PULP_DATABASE_SSLMODE}" \
  PGSSLROOTCERT="${PULP_DATABASE_SSLROOTCERT:-}" \
    pg_dump \
      --host "${PULP_DATABASE_HOST}" \
      --port "${PULP_DATABASE_PORT}" \
      --username "${PULP_DATABASE_USER}" \
      --dbname "${PULP_DATABASE_NAME}" \
      --format=custom \
      --no-owner \
      --no-acl \
      --file=/work/databases/pulp.dump
}

restore_database() {
  name="$1"
  dump="$2"
  shift 2

  log "Restoring ${name} database"
  pg_restore \
    --clean \
    --if-exists \
    --no-owner \
    --no-acl \
    --exit-on-error \
    "$@" \
    "${dump}"
}

resolve_snapshot() {
  if [ "${RESTORE_SNAPSHOT}" = latest ]; then
    snapshot_json="$(
      restic snapshots \
        --json \
        --latest 1 \
        --host "${HELM_RELEASE}" \
        --tag foreman-stack
    )"
  else
    snapshot_json="$(restic snapshots --json "${RESTORE_SNAPSHOT}")"
  fi

  snapshot_id="$(
    printf '%s' "${snapshot_json}" |
      jq -er --arg release "${HELM_RELEASE}" '
        if length != 1 then
          error("expected exactly one recovery snapshot")
        elif .[0].hostname != $release then
          error("snapshot belongs to a different Helm release")
        elif (.[0].tags | index("foreman-stack")) == null then
          error("snapshot is missing the foreman-stack tag")
        else
          .[0].id
        end
      '
  )"

  printf '%s\n' "${snapshot_id}"
}
