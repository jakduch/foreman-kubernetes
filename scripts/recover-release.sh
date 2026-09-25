#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
  echo "usage: $0 {backup|restore|resume} APPLICATION_VALUES EXECUTION_PROXY_VALUES [REQUEST_ID]" >&2
  exit 2
fi

operation="$1"
application_values="$2"
execution_values="$3"
request_id="${4:-}"
case "${operation}" in
  backup | restore)
    [[ -n "${request_id}" ]] || {
      echo "${operation} requires a request ID" >&2
      exit 2
    }
    ;;
  resume)
    [[ -z "${request_id}" ]] || {
      echo 'resume does not accept a request ID' >&2
      exit 2
    }
    ;;
  *)
    echo "unsupported recovery operation: ${operation}" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=release-preflight.sh
. "${repo_root}/scripts/release-preflight.sh"
namespace="${NAMESPACE:-foreman}"
application_release="${APPLICATION_RELEASE:-foreman}"
execution_release="${EXECUTION_RELEASE:-execution}"
compatibility_sets_file="${repo_root}/compatibility/release-sets.json"
compatibility_set="${COMPATIBILITY_SET:-}"
allow_candidate="${ALLOW_CANDIDATE:-0}"
recovery_timeout="${RECOVERY_TIMEOUT:-6h}"
resume_timeout="${RESUME_TIMEOUT:-30m}"
smoke_timeout="${SMOKE_TIMEOUT:-10m}"
initialize_repository="${INITIALIZE_REPOSITORY:-0}"
restore_snapshot="${RESTORE_SNAPSHOT:-latest}"
restore_secrets="${RESTORE_SECRETS:-0}"
object_storage_confirmation="${OBJECT_STORAGE_CONFIRMATION:-}"
release_lease_name="${RELEASE_LEASE_NAME:-foreman-kubernetes-release}"
release_holder_id="${RELEASE_HOLDER_ID:-${HOSTNAME:-recovery-host}-${operation}-$$}"
release_lease_duration_seconds="${RELEASE_LEASE_DURATION_SECONDS:-120}"
release_lease_renew_interval_seconds="${RELEASE_LEASE_RENEW_INTERVAL_SECONDS:-30}"
release_lease_acquired=false
release_lease_renewal_pid=''

fail() {
  echo "$1" >&2
  exit 1
}

cleanup() {
  local exit_status=$?

  set +e
  release_operation_lease "${namespace}" "${release_lease_name}" "${release_holder_id}"
  return "${exit_status}"
}
trap cleanup EXIT
trap 'fail "release Lease renewal failed; the recovery operation was stopped"' TERM

for command_name in helm jq kubectl grep ruby; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} is required"
done

[[ -f "${application_values}" ]] || fail "application values do not exist: ${application_values}"
[[ -f "${execution_values}" ]] || fail "execution proxy values do not exist: ${execution_values}"

case "${allow_candidate}" in
  0 | 1) ;;
  *) fail 'ALLOW_CANDIDATE must be 0 or 1' ;;
esac
case "${initialize_repository}" in
  0 | 1) ;;
  *) fail 'INITIALIZE_REPOSITORY must be 0 or 1' ;;
esac
case "${restore_secrets}" in
  0 | 1) ;;
  *) fail 'RESTORE_SECRETS must be 0 or 1' ;;
esac
validate_release_lease_configuration "${release_lease_duration_seconds}" \
  "${release_lease_renew_interval_seconds}" || exit 1

if [[ -z "${compatibility_set}" ]]; then
  compatibility_set="$(jq --exit-status --raw-output '.default' \
    "${compatibility_sets_file}")"
fi
release_set="$(jq --exit-status --compact-output --arg set "${compatibility_set}" \
  '.sets[$set]' "${compatibility_sets_file}")" || \
  fail "unknown compatibility set: ${compatibility_set}"
release_set_status="$(jq --exit-status --raw-output '.status' <<<"${release_set}")"
case "${release_set_status}" in
  supported) ;;
  candidate)
    [[ "${allow_candidate}" == 1 ]] || \
      fail "compatibility set ${compatibility_set} is still a candidate; set ALLOW_CANDIDATE=1 only for qualification"
    ;;
  retired) fail "compatibility set ${compatibility_set} is retired and cannot be recovered" ;;
  *) fail "unsupported compatibility-set state: ${release_set_status}" ;;
esac

application_profile="${repo_root}/$(jq --exit-status --raw-output \
  '.applicationProfile' <<<"${release_set}")"
execution_profile="${repo_root}/$(jq --exit-status --raw-output \
  '.executionProxyProfile' <<<"${release_set}")"
[[ -f "${application_profile}" ]] || fail "application profile does not exist: ${application_profile}"
[[ -f "${execution_profile}" ]] || fail "execution profile does not exist: ${execution_profile}"

kubectl get namespace "${namespace}" >/dev/null || fail "namespace ${namespace} does not exist"
acquire_release_lease "${namespace}" "${release_lease_name}" \
  "${release_holder_id}" "${release_lease_duration_seconds}" \
  "recovery-${operation}" "${compatibility_set}" || \
  fail 'another release operation is active or its Lease cannot be claimed safely'
start_release_lease_renewal "${namespace}" "${release_lease_name}" \
  "${release_holder_id}" "${release_lease_duration_seconds}" \
  "${release_lease_renew_interval_seconds}"

application_installed_set="$(helm get values "${application_release}" \
  --namespace "${namespace}" --all --output=json | \
  jq --exit-status --raw-output '.platform.compatibilitySet | select(type == "string" and length > 0)')" || \
  fail "cannot determine the installed compatibility set for ${application_release}"
execution_installed_set="$(helm get values "${execution_release}" \
  --namespace "${namespace}" --all --output=json | \
  jq --exit-status --raw-output '.compatibilitySet | select(type == "string" and length > 0)')" || \
  fail "cannot determine the installed compatibility set for ${execution_release}"
if [[ "${application_installed_set}" != "${compatibility_set}" || \
      "${execution_installed_set}" != "${compatibility_set}" ]]; then
  fail "recovery requires application and execution proxy on ${compatibility_set}; found ${application_installed_set} and ${execution_installed_set}"
fi

helm status "${application_release}" --namespace "${namespace}" >/dev/null
helm status "${execution_release}" --namespace "${namespace}" >/dev/null

declare -a recovery_arguments application_maintenance_arguments
declare -a application_normal_arguments execution_maintenance_arguments
declare -a execution_normal_arguments
recovery_arguments=()
application_maintenance_arguments=(
  --set maintenance.enabled=true
  --set backup.enabled=false
  --set restore.enabled=false
)
application_normal_arguments=(
  --set maintenance.enabled=false
  --set backup.enabled=false
  --set restore.enabled=false
)
execution_maintenance_arguments=(
  --set maintenance.enabled=true
  --set smokeTest.enabled=false
)
execution_normal_arguments=(--set maintenance.enabled=false)

if [[ "${operation}" != resume ]]; then
  kubectl --namespace "${namespace}" wait \
    --for=condition=Ready pod \
    --selector="app.kubernetes.io/instance=${execution_release},app.kubernetes.io/component=execution-proxy" \
    --timeout="${smoke_timeout}"
  helm test "${application_release}" \
    --namespace "${namespace}" \
    --logs \
    --timeout "${smoke_timeout}"
  helm test "${execution_release}" \
    --namespace "${namespace}" \
    --logs \
    --timeout "${smoke_timeout}"

  recovery_arguments+=(
    --set maintenance.enabled=true
    --set backup.enabled=false
    --set restore.enabled=false
    --set "${operation}.enabled=true"
    --set-string "${operation}.requestId=${request_id}"
  )
  if [[ "${operation}" == backup ]]; then
    recovery_arguments+=(--set "backup.initializeRepository=$([[ "${initialize_repository}" == 1 ]] && echo true || echo false)")
  else
    recovery_arguments+=(
      --set-string "restore.snapshot=${restore_snapshot}"
      --set restore.confirmation=RESTORE
      --set "restore.secrets=$([[ "${restore_secrets}" == 1 ]] && echo true || echo false)"
    )
    if [[ -n "${object_storage_confirmation}" ]]; then
      recovery_arguments+=(--set-string "restore.objectStorageConfirmation=${object_storage_confirmation}")
    fi
  fi
fi

echo "Preflight: rendering ${operation} for compatibility set ${compatibility_set}"
helm lint "${repo_root}/charts/foreman-stack" \
  --values "${application_values}" \
  --values "${application_profile}" \
  "${application_normal_arguments[@]}"
application_normal_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  "${application_normal_arguments[@]}")"
helm lint "${repo_root}/charts/foreman-execution-proxy" \
  --values "${execution_values}" \
  --values "${execution_profile}" \
  "${execution_normal_arguments[@]}"
execution_normal_resources="$(helm template "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
  --namespace "${namespace}" \
  --values "${execution_values}" \
  --values "${execution_profile}" \
  "${execution_normal_arguments[@]}")"
normal_resources="$(printf '%s\n---\n%s\n' \
  "${application_normal_resources}" "${execution_normal_resources}")"

if [[ "${operation}" == resume ]]; then
  all_resources="${normal_resources}"
  check_required_cluster_resources "${all_resources}" "${namespace}" "${repo_root}"
  check_required_secrets "${all_resources}" "${namespace}" "${repo_root}"
  check_server_admission "${normal_resources}" "${namespace}"
else
  helm lint "${repo_root}/charts/foreman-stack" \
    --values "${application_values}" \
    --values "${application_profile}" \
    "${application_maintenance_arguments[@]}"
  application_maintenance_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
    --namespace "${namespace}" \
    --values "${application_values}" \
    --values "${application_profile}" \
    "${application_maintenance_arguments[@]}")"
  helm lint "${repo_root}/charts/foreman-execution-proxy" \
    --values "${execution_values}" \
    --values "${execution_profile}" \
    "${execution_maintenance_arguments[@]}"
  execution_maintenance_resources="$(helm template "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
    --namespace "${namespace}" \
    --values "${execution_values}" \
    --values "${execution_profile}" \
    "${execution_maintenance_arguments[@]}")"
  helm lint "${repo_root}/charts/foreman-stack" \
    --values "${application_values}" \
    --values "${application_profile}" \
    "${recovery_arguments[@]}"
  application_recovery_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
    --namespace "${namespace}" \
    --values "${application_values}" \
    --values "${application_profile}" \
    "${recovery_arguments[@]}")"
  if [[ "$(grep -Fxc 'kind: Job' <<<"${application_recovery_resources}")" != 1 ]]; then
    fail "${operation} must render exactly one recovery Job"
  fi

  maintenance_resources="$(printf '%s\n---\n%s\n' \
    "${application_maintenance_resources}" "${execution_maintenance_resources}")"
  recovery_resources="$(printf '%s\n---\n%s\n' \
    "${application_recovery_resources}" "${execution_maintenance_resources}")"
  all_resources="$(printf '%s\n---\n%s\n' "${normal_resources}" "${recovery_resources}")"
  check_required_cluster_resources "${all_resources}" "${namespace}" "${repo_root}"
  check_required_secrets "${all_resources}" "${namespace}" "${repo_root}"
  check_server_admission "${maintenance_resources}" "${namespace}"
  check_server_admission "${recovery_resources}" "${namespace}"
  check_server_admission "${normal_resources}" "${namespace}"
fi

if [[ "${operation}" != resume ]]; then
  echo 'Recovery: stopping application writers'
  if ! helm upgrade "${application_release}" "${repo_root}/charts/foreman-stack" \
    --namespace "${namespace}" \
    --values "${application_values}" \
    --values "${application_profile}" \
    "${application_maintenance_arguments[@]}" \
    --wait \
    --wait-for-jobs \
    --timeout "${resume_timeout}"; then
    fail 'application maintenance mode did not become ready; inspect the release before retrying'
  fi

  echo 'Recovery: stopping the execution proxy'
  if ! helm upgrade "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
    --namespace "${namespace}" \
    --values "${execution_values}" \
    --values "${execution_profile}" \
    "${execution_maintenance_arguments[@]}" \
    --wait \
    --timeout "${resume_timeout}"; then
    fail 'the execution proxy did not enter maintenance; the application remains stopped'
  fi
  kubectl --namespace "${namespace}" wait \
    --for=delete pod \
    --selector="app.kubernetes.io/instance=${execution_release},app.kubernetes.io/component=execution-proxy" \
    --timeout="${resume_timeout}" || \
    fail 'the execution proxy Pod did not terminate; both releases remain in maintenance mode'

  echo "Recovery: running ${operation} ${request_id}"
  if ! helm upgrade "${application_release}" "${repo_root}/charts/foreman-stack" \
    --namespace "${namespace}" \
    --values "${application_values}" \
    --values "${application_profile}" \
    "${recovery_arguments[@]}" \
    --wait \
    --wait-for-jobs \
    --timeout "${recovery_timeout}"; then
    fail "${operation} failed; the application and execution proxy remain in maintenance mode for inspection or a guarded retry"
  fi
fi

echo 'Recovery: restoring the normal application release'
if ! helm upgrade "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  "${application_normal_arguments[@]}" \
  --wait \
  --wait-for-jobs \
  --timeout "${resume_timeout}"; then
  fail 'the recovery action completed, but the normal application release did not become ready'
fi

echo 'Recovery: restoring the execution proxy'
if ! helm upgrade "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
  --namespace "${namespace}" \
  --values "${execution_values}" \
  --values "${execution_profile}" \
  "${execution_normal_arguments[@]}" \
  --wait \
  --timeout "${resume_timeout}"; then
  fail 'the application is ready, but the execution proxy did not leave maintenance mode'
fi

kubectl --namespace "${namespace}" wait \
  --for=condition=Ready pod \
  --selector="app.kubernetes.io/instance=${execution_release},app.kubernetes.io/component=execution-proxy" \
  --timeout="${smoke_timeout}"
helm test "${application_release}" \
  --namespace "${namespace}" \
  --logs \
  --timeout "${smoke_timeout}"
helm test "${execution_release}" \
  --namespace "${namespace}" \
  --logs \
  --timeout "${smoke_timeout}"

echo "Recovery operation ${operation} completed with compatibility set ${compatibility_set}."
