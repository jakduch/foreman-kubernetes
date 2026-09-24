#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 APPLICATION_VALUES EXECUTION_PROXY_VALUES" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=release-preflight.sh
. "${repo_root}/scripts/release-preflight.sh"
application_values="$1"
execution_values="$2"
namespace="${NAMESPACE:-foreman}"
application_release="${APPLICATION_RELEASE:-foreman}"
execution_release="${EXECUTION_RELEASE:-execution}"
compatibility_sets_file="${repo_root}/compatibility/release-sets.json"
compatibility_set="${COMPATIBILITY_SET:-}"
allow_candidate="${ALLOW_CANDIDATE:-0}"
wait_timeout="${UPGRADE_TIMEOUT:-30m}"
preflight_timeout="${PREFLIGHT_TIMEOUT:-10m}"
upgrade_lock_name="${UPGRADE_LOCK_NAME:-foreman-kubernetes-upgrade-lock}"
upgrade_holder_id="${UPGRADE_HOLDER_ID:-${HOSTNAME:-upgrade-host}-$$}"
upgrade_lock_acquired=false

fail() {
  echo "$1" >&2
  exit 1
}

release_upgrade_lock() {
  local current_holder

  [[ "${upgrade_lock_acquired}" == true ]] || return 0
  current_holder="$(kubectl --namespace "${namespace}" get configmap \
    "${upgrade_lock_name}" --output=jsonpath='{.data.holder}' 2>/dev/null || true)"
  if [[ "${current_holder}" == "${upgrade_holder_id}" ]]; then
    kubectl --namespace "${namespace}" delete configmap \
      "${upgrade_lock_name}" --wait=true >/dev/null
  else
    echo "upgrade lock holder changed to ${current_holder:-unknown}; leaving the lock untouched" >&2
  fi
}

cleanup() {
  local exit_status=$?

  set +e
  release_upgrade_lock
  return "${exit_status}"
}
trap cleanup EXIT

for command_name in helm jq kubectl grep ruby; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "${command_name} is required"
done

[[ -f "${application_values}" ]] || fail "application values do not exist: ${application_values}"
[[ -f "${execution_values}" ]] || fail "execution proxy values do not exist: ${execution_values}"

case "${allow_candidate}" in
  0 | 1) ;;
  *) fail 'ALLOW_CANDIDATE must be 0 or 1' ;;
esac

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
  retired)
    fail "compatibility set ${compatibility_set} is retired and cannot be installed"
    ;;
  *) fail "unsupported compatibility-set state: ${release_set_status}" ;;
esac

application_profile="${repo_root}/$(jq --exit-status --raw-output \
  '.applicationProfile' <<<"${release_set}")"
execution_profile="${repo_root}/$(jq --exit-status --raw-output \
  '.executionProxyProfile' <<<"${release_set}")"
[[ -f "${application_profile}" ]] || fail "application profile does not exist: ${application_profile}"
[[ -f "${execution_profile}" ]] || fail "execution profile does not exist: ${execution_profile}"

if ! kubectl --namespace "${namespace}" create configmap "${upgrade_lock_name}" \
  --from-literal="holder=${upgrade_holder_id}" \
  --from-literal="compatibility-set=${compatibility_set}" >/dev/null; then
  existing_holder="$(kubectl --namespace "${namespace}" get configmap \
    "${upgrade_lock_name}" --output=jsonpath='{.data.holder}' 2>/dev/null || true)"
  fail "upgrade lock ${upgrade_lock_name} is already held by ${existing_holder:-unknown}"
fi
upgrade_lock_acquired=true

echo "Preflight: checking current ${application_release} and ${execution_release} releases"
helm status "${application_release}" --namespace "${namespace}" >/dev/null
helm status "${execution_release}" --namespace "${namespace}" >/dev/null
kubectl --namespace "${namespace}" wait \
  --for=condition=Ready pod \
  --selector="app.kubernetes.io/instance=${execution_release},app.kubernetes.io/component=execution-proxy" \
  --timeout="${preflight_timeout}"
helm test "${application_release}" \
  --namespace "${namespace}" \
  --logs \
  --timeout "${preflight_timeout}"

echo "Preflight: rendering compatibility set ${compatibility_set}"
helm lint "${repo_root}/charts/foreman-stack" \
  --values "${application_values}" \
  --values "${application_profile}"
application_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}")"
foreman_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  --show-only templates/foreman.yaml)"
grep -Fxq 'kind: Deployment' <<<"${foreman_resources}" || \
  fail 'normal upgrade requires the Foreman Deployment; maintenance mode is not supported by this helper'
dynflow_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  --show-only templates/dynflow.yaml)"
[[ "$(grep -Fxc 'kind: Deployment' <<<"${dynflow_resources}")" == 3 ]] || \
  fail 'normal upgrade requires all three Dynflow Deployments'
migration_resources="$(helm template "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  --show-only templates/migrations.yaml)"
[[ "$(grep -Fxc 'kind: Job' <<<"${migration_resources}")" == 3 ]] || \
  fail 'normal upgrade requires all three chart-owned migration Jobs'
helm lint "${repo_root}/charts/foreman-execution-proxy" \
  --values "${execution_values}" \
  --values "${execution_profile}"
execution_resources="$(helm template "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
  --namespace "${namespace}" \
  --values "${execution_values}" \
  --values "${execution_profile}")"

combined_resources="$(printf '%s\n---\n%s\n' "${application_resources}" "${execution_resources}")"
check_required_cluster_resources "${combined_resources}" "${namespace}" "${repo_root}"
check_required_secrets "${combined_resources}" "${namespace}" "${repo_root}"

echo "Upgrade: applying the application release and migration gates"
if ! helm upgrade "${application_release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${application_values}" \
  --values "${application_profile}" \
  --wait \
  --wait-for-jobs \
  --timeout "${wait_timeout}"; then
  fail 'application upgrade failed; inspect migration and workload Jobs before retrying'
fi

if ! helm test "${application_release}" \
  --namespace "${namespace}" \
  --logs \
  --timeout "${preflight_timeout}"; then
  fail 'application revision is installed but its smoke test failed; do not roll back automatically after schema migrations'
fi

echo "Upgrade: applying the paired execution-proxy release"
if ! helm upgrade "${execution_release}" "${repo_root}/charts/foreman-execution-proxy" \
  --namespace "${namespace}" \
  --values "${execution_values}" \
  --values "${execution_profile}" \
  --wait \
  --timeout "${wait_timeout}"; then
  fail 'application upgrade succeeded but execution-proxy upgrade failed; repair or roll the proxy forward without rolling back migrated schemas'
fi

kubectl --namespace "${namespace}" wait \
  --for=condition=Ready pod \
  --selector="app.kubernetes.io/instance=${execution_release},app.kubernetes.io/component=execution-proxy" \
  --timeout="${preflight_timeout}"
helm test "${application_release}" \
  --namespace "${namespace}" \
  --logs \
  --timeout "${preflight_timeout}"

echo "Compatibility set ${compatibility_set} is deployed. Run a real Remote Execution workflow before completing the change window."
