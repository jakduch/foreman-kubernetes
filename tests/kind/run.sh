#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cluster_name="${KIND_CLUSTER_NAME:-foreman-stack-e2e}"
namespace="foreman"
release="foreman"
compatibility_sets_file="${repo_root}/compatibility/release-sets.json"
compatibility_set="${COMPATIBILITY_SET:-}"
image_profile="${IMAGE_PROFILE:-}"
execution_proxy_image_profile="${EXECUTION_PROXY_IMAGE_PROFILE:-}"
kind_node_image="${KIND_NODE_IMAGE:-kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d}"
created_cluster=false
temporary_directory="$(mktemp -d)"
skip_recovery_test="${SKIP_RECOVERY_TEST:-0}"
content_lifecycle_state="${temporary_directory}/content-lifecycle.json"
image_runtime_contract_file="${IMAGE_RUNTIME_CONTRACT_FILE:-artifacts/image-runtime-contract.json}"
candlepin_job_delivery_file="${CANDLEPIN_JOB_DELIVERY_FILE:-artifacts/candlepin-job-delivery.json}"
operator_release_evidence_file="${OPERATOR_RELEASE_EVIDENCE_FILE:-artifacts/operator-release.json}"
pulp_object_storage_evidence_file="${PULP_OBJECT_STORAGE_EVIDENCE_FILE:-artifacts/pulp-object-storage.json}"
foreman_database_url_backup=""
candlepin_database_password_backup=""
application_secret_rollout_token=initial
execution_secret_rollout_token=initial
candlepin_java_xms=512m
recovery_allow_candidate=0
recovery_application_profile_override=""
recovery_execution_profile_override=""

wait_for_migration_jobs() {
  local operation_id="$1"
  local expected_jobs="$2"
  local timeout_seconds="${KIND_MIGRATION_WAIT_SECONDS:-1800}"
  local deadline=$((SECONDS + timeout_seconds))
  local jobs
  local failed_jobs
  local complete_jobs
  local total_jobs
  local job_name

  while ((SECONDS < deadline)); do
    jobs="$(kubectl --namespace "${namespace}" get jobs \
      --selector="platform.theforeman.org/release-operation=${operation_id}" \
      --output=json)"
    failed_jobs="$(jq --raw-output \
      '.items[] |
       select(any(.status.conditions[]?; .type == "Failed" and .status == "True")) |
       .metadata.name' <<<"${jobs}")"
    if [[ -n "${failed_jobs}" ]]; then
      echo "Migration operation ${operation_id} failed in: ${failed_jobs//$'\n'/, }" >&2
      while IFS= read -r job_name; do
        [[ -n "${job_name}" ]] || continue
        kubectl --namespace "${namespace}" logs \
          "job/${job_name}" --all-containers=true --tail=100 >&2 || true
      done <<<"${failed_jobs}"
      return 1
    fi

    total_jobs="$(jq '.items | length' <<<"${jobs}")"
    complete_jobs="$(jq \
      '[.items[] |
        select(any(.status.conditions[]?; .type == "Complete" and .status == "True"))] |
       length' <<<"${jobs}")"
    if [[ "${total_jobs}" -eq "${expected_jobs}" && \
      "${complete_jobs}" -eq "${expected_jobs}" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "Migration operation ${operation_id} did not finish within ${timeout_seconds}s" >&2
  kubectl --namespace "${namespace}" get jobs \
    --selector="platform.theforeman.org/release-operation=${operation_id}" >&2 || true
  return 1
}

helm_apply() {
  local expected_migration_jobs
  local operation_id
  local migration_stage

  if [[ " $* " == *' maintenance.enabled=true '* ]]; then
    helm upgrade --install "${release}" "${repo_root}/charts/foreman-stack" \
      --namespace "${namespace}" \
      --values "${repo_root}/tests/kind/values.yaml" \
      --values "${repo_root}/examples/execution-control-plane-values.yaml" \
      --values "${image_profile}" \
      --set-string secretRolloutToken="${application_secret_rollout_token}" \
      --set-string candlepin.java.xms="${candlepin_java_xms}" \
      --wait \
      --wait-for-jobs \
      --timeout 30m \
      "$@"
    return
  fi

  operation_id="kind-$(date -u +%Y%m%d%H%M%S)-$$-${RANDOM}"
  migration_stage="$(helm template "${release}" "${repo_root}/charts/foreman-stack" \
    --namespace "${namespace}" \
    --values "${repo_root}/tests/kind/values.yaml" \
    --values "${repo_root}/examples/execution-control-plane-values.yaml" \
    --values "${image_profile}" \
    --set-string secretRolloutToken="${application_secret_rollout_token}" \
    --set-string candlepin.java.xms="${candlepin_java_xms}" \
    "$@" \
    --set-string "releaseOperation.id=${operation_id}" \
    --set-string "releaseOperation.ownerUid=${operation_id}" | \
    ruby "${repo_root}/scripts/render-migration-stage.rb" "${release}" "${namespace}")"
  expected_migration_jobs="$(awk \
    '/^kind: Job$/ { count++ } END { print count + 0 }' <<<"${migration_stage}")"
  if [[ "${expected_migration_jobs}" -lt 1 ]]; then
    echo "Migration operation ${operation_id} rendered no Jobs" >&2
    return 1
  fi
  printf '%s\n' "${migration_stage}" | kubectl --namespace "${namespace}" apply --filename -
  if ! wait_for_migration_jobs "${operation_id}" "${expected_migration_jobs}"; then
    return 1
  fi

  helm upgrade --install "${release}" "${repo_root}/charts/foreman-stack" \
    --namespace "${namespace}" \
    --values "${repo_root}/tests/kind/values.yaml" \
    --values "${repo_root}/examples/execution-control-plane-values.yaml" \
    --values "${image_profile}" \
    --set-string secretRolloutToken="${application_secret_rollout_token}" \
    --set-string candlepin.java.xms="${candlepin_java_xms}" \
    "$@" \
    --set releaseOperation.skipMigrationJobs=true \
    --wait \
    --wait-for-jobs \
    --timeout 30m
}

helm_execution_apply() {
  helm upgrade --install execution "${repo_root}/charts/foreman-execution-proxy" \
    --namespace "${namespace}" \
    --values "${repo_root}/tests/kind/execution-proxy-values.yaml" \
    --values "${execution_proxy_image_profile}" \
    --set-string secretRolloutToken="${execution_secret_rollout_token}" \
    --wait \
    --timeout 15m \
    "$@"
}

run_recovery() {
  local operation="$1"
  local request_id="$2"

  ALLOW_CANDIDATE="${recovery_allow_candidate}" \
    COMPATIBILITY_SET="${compatibility_set}" \
    NAMESPACE="${namespace}" \
    INITIALIZE_REPOSITORY="$([[ "${operation}" == backup ]] && echo 1 || echo 0)" \
    RESTORE_SECRETS="$([[ "${operation}" == restore ]] && echo 1 || echo 0)" \
    BOOTSTRAP_RESTORE="$([[ "${operation}" == restore ]] && echo 1 || echo 0)" \
    APPLICATION_PROFILE_OVERRIDE="${recovery_application_profile_override}" \
    EXECUTION_PROXY_PROFILE_OVERRIDE="${recovery_execution_profile_override}" \
    "${repo_root}/scripts/recover-release.sh" \
      "${operation}" \
      "${repo_root}/tests/kind/values.yaml" \
      "${repo_root}/tests/kind/execution-proxy-values.yaml" \
      "${request_id}"
}

foreman_pod() {
  kubectl --namespace "${namespace}" get pod \
    --selector=app.kubernetes.io/component=foreman \
    --output=jsonpath='{.items[0].metadata.name}'
}

pulp_worker_pod() {
  kubectl --namespace "${namespace}" get pod \
    --selector=app.kubernetes.io/component=pulp-worker \
    --output=jsonpath='{.items[0].metadata.name}'
}

dynflow_worker_pod() {
  kubectl --namespace "${namespace}" get pod \
    --selector=app.kubernetes.io/component=dynflow-worker \
    --output=jsonpath='{.items[0].metadata.name}'
}

pod_uids() {
  local selector="$1"

  kubectl --namespace "${namespace}" get pods \
    --selector="${selector}" \
    --output=json | jq --raw-output '.items[].metadata.uid' | sort
}

application_workload_pod_uids() {
  kubectl --namespace "${namespace}" get pods \
    --selector="app.kubernetes.io/instance=${release}" \
    --output=json | jq --raw-output '
      [.items[] |
       select(any(.metadata.ownerReferences[]?; .kind == "ReplicaSet")) |
       [.metadata.labels["app.kubernetes.io/component"], .metadata.uid]] |
      sort_by(.[0], .[1])[] |
      @tsv'
}

assert_application_workloads_unchanged() {
  local previous_uids="$1"
  local current_uids

  current_uids="$(application_workload_pod_uids)"
  if [[ -z "${previous_uids}" || -z "${current_uids}" ]]; then
    echo 'Cannot prove application workload Pod retention' >&2
    exit 1
  fi
  if [[ "${current_uids}" != "${previous_uids}" ]]; then
    echo 'Application workload Pods changed before migrations succeeded' >&2
    diff -u <(printf '%s\n' "${previous_uids}") \
      <(printf '%s\n' "${current_uids}") >&2 || true
    exit 1
  fi
}

assert_pods_replaced() {
  local selector="$1"
  local previous_uids="$2"
  local current_uids
  local previous_uid

  current_uids="$(pod_uids "${selector}")"
  if [[ -z "${previous_uids}" || -z "${current_uids}" ]]; then
    echo "Cannot prove Pod replacement for selector ${selector}" >&2
    exit 1
  fi
  while IFS= read -r previous_uid; do
    if grep -Fxq "${previous_uid}" <<<"${current_uids}"; then
      echo "Pod ${previous_uid} for selector ${selector} survived a configuration-changing upgrade" >&2
      exit 1
    fi
  done <<<"${previous_uids}"
}

assert_pods_unchanged() {
  local selector="$1"
  local previous_uids="$2"
  local current_uids

  current_uids="$(pod_uids "${selector}")"
  if [[ -z "${previous_uids}" || -z "${current_uids}" ]]; then
    echo "Cannot prove Pod retention for selector ${selector}" >&2
    exit 1
  fi
  if [[ "${current_uids}" != "${previous_uids}" ]]; then
    echo "Pods for selector ${selector} changed before migrations succeeded" >&2
    exit 1
  fi
}

assert_foreman_ready() {
  curl --fail --silent --show-error \
    --retry 60 \
    --retry-all-errors \
    --retry-delay 5 \
    --cacert "${temporary_directory}/ca.crt" \
    --resolve foreman.test:8443:127.0.0.1 \
    https://foreman.test:8443/api/v2/ping >/dev/null

  curl --fail --silent --show-error \
    --cacert "${temporary_directory}/ca.crt" \
    --cert "${temporary_directory}/foreman-client.crt" \
    --key "${temporary_directory}/foreman-client.key" \
    --resolve foreman.test:8443:127.0.0.1 \
    https://foreman.test:8443/api/v2/ping >/dev/null
}

assert_pulp_registration() {
  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    bin/rails runner 'abort "Pulp proxy missing" unless SmartProxy.pulp_primary&.has_feature?("Pulpcore")'
}

assert_application_smoke_test() {
  helm test "${release}" \
    --namespace "${namespace}" \
    --logs \
    --timeout 10m
}

write_integration_evidence() {
  local evidence_file="${INTEGRATION_EVIDENCE_FILE:-}"
  local result=passed

  [[ -n "${evidence_file}" ]] || return 0
  if [[ "${skip_recovery_test}" == 1 ]]; then
    result=partial
  fi
  ruby "${repo_root}/scripts/write-integration-evidence.rb" \
    "${evidence_file}" \
    "${compatibility_set}" \
    "${image_profile}" \
    "${execution_proxy_image_profile}" \
    "${result}"
}

candlepin_quartz_instances() {
  kubectl --namespace "${namespace}" exec deployment/postgresql -- \
    env PGPASSWORD=candlepin-test \
    psql \
    --host=127.0.0.1 \
    --username=candlepin \
    --dbname=candlepin \
    --tuples-only \
    --no-align \
    --command="SELECT instance_name FROM qrtz_scheduler_state WHERE sched_name = 'ForemanCandlepinKind' ORDER BY instance_name"
}

wait_for_candlepin_quartz_instances() {
  local expected_count="$1"
  local actual_count
  local instances

  for _ in $(seq 1 120); do
    instances="$(candlepin_quartz_instances)"
    actual_count="$(printf '%s\n' "${instances}" | awk 'NF { count++ } END { print count + 0 }')"
    if [[ "${actual_count}" == "${expected_count}" ]]; then
      printf '%s\n' "${instances}"
      return 0
    fi
    sleep 2
  done

  echo "Quartz has ${actual_count} registered instances, expected ${expected_count}" >&2
  printf '%s\n' "${instances}" >&2
  return 1
}

assert_candlepin_ha() {
  local ready_replicas

  kubectl --namespace "${namespace}" rollout status \
    deployment/foreman-foreman-stack-candlepin \
    --timeout=10m

  ready_replicas="$(
    kubectl --namespace "${namespace}" get \
      deployment/foreman-foreman-stack-candlepin \
      --output=jsonpath='{.status.readyReplicas}'
  )"
  if [[ "${ready_replicas}" != 2 ]]; then
    echo "Candlepin has ${ready_replicas:-0} ready replicas, expected 2" >&2
    exit 1
  fi

  wait_for_candlepin_quartz_instances 2 >/dev/null
}

assert_candlepin_pod_recovery() {
  local after_instances
  local before_instances
  local candlepin_pod

  before_instances="$(candlepin_quartz_instances)"
  candlepin_pod="$(
    kubectl --namespace "${namespace}" get pod \
      --selector=app.kubernetes.io/component=candlepin \
      --output=jsonpath='{.items[0].metadata.name}'
  )"
  kubectl --namespace "${namespace}" delete pod "${candlepin_pod}" \
    --wait=true \
    --timeout=5m

  assert_candlepin_ha
  after_instances="$(candlepin_quartz_instances)"
  if [[ "${before_instances}" == "${after_instances}" ]]; then
    echo "Quartz did not replace the terminated scheduler instance" >&2
    exit 1
  fi
  assert_foreman_ready
}

set_database_probes() {
  local expected_value="$1"
  local database

  for database in foreman candlepin pulp; do
    kubectl --namespace "${namespace}" exec deployment/postgresql -- \
      env "PGPASSWORD=${database}-test" \
      psql \
      --host=127.0.0.1 \
      --username="${database}" \
      --dbname="${database}" \
      --set=ON_ERROR_STOP=1 \
      --command="CREATE TABLE IF NOT EXISTS foreman_kubernetes_recovery_probe (value text NOT NULL); TRUNCATE foreman_kubernetes_recovery_probe; INSERT INTO foreman_kubernetes_recovery_probe VALUES ('${expected_value}');"
  done
}

assert_database_probes() {
  local expected_value="$1"
  local actual_value
  local database

  for database in foreman candlepin pulp; do
    actual_value="$(
      kubectl --namespace "${namespace}" exec deployment/postgresql -- \
        env "PGPASSWORD=${database}-test" \
        psql \
        --host=127.0.0.1 \
        --username="${database}" \
        --dbname="${database}" \
        --tuples-only \
        --no-align \
        --command='SELECT value FROM foreman_kubernetes_recovery_probe'
    )"
    if [[ "${actual_value}" != "${expected_value}" ]]; then
      echo "${database} recovery probe is '${actual_value}', expected '${expected_value}'" >&2
      exit 1
    fi
  done
}

set_pulp_probe() {
  local expected_value="$1"

  # The inner shell expands its positional argument inside the container.
  # shellcheck disable=SC2016
  kubectl --namespace "${namespace}" exec "$(pulp_worker_pod)" -- \
    sh -c 'printf "%s\n" "$1" > /var/lib/pulp/recovery-probe' sh "${expected_value}"
}

assert_pulp_probe() {
  local expected_value="$1"
  local actual_value

  actual_value="$(
    kubectl --namespace "${namespace}" exec "$(pulp_worker_pod)" -- \
      sh -c 'cat /var/lib/pulp/recovery-probe'
  )"
  if [[ "${actual_value}" != "${expected_value}" ]]; then
    echo "Pulp recovery probe is '${actual_value}', expected '${expected_value}'" >&2
    exit 1
  fi
}

set_avatar_probe() {
  local expected_value="$1"

  # The inner shell expands its positional argument inside the container.
  # shellcheck disable=SC2016
  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    sh -c 'printf "%s\n" "$1" > /usr/share/foreman/public/images/avatars/recovery-probe' sh "${expected_value}"
}

assert_avatar_probe() {
  local expected_value="$1"
  local actual_value

  actual_value="$(
    kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
      sh -c 'cat /usr/share/foreman/public/images/avatars/recovery-probe'
  )"
  if [[ "${actual_value}" != "${expected_value}" ]]; then
    echo "Foreman avatar recovery probe is '${actual_value}', expected '${expected_value}'" >&2
    exit 1
  fi
}

set_execution_state_probe() {
  local expected_value="$1"

  # The inner shell expands its positional argument inside the container.
  # shellcheck disable=SC2016
  kubectl --namespace "${namespace}" exec \
    deployment/execution-foreman-execution-proxy -- \
    sh -c 'printf "%s\n" "$1" > /var/lib/foreman-proxy/recovery-probe' \
    sh "${expected_value}"
}

assert_execution_state_probe() {
  local expected_value="$1"
  local actual_value

  actual_value="$(
    kubectl --namespace "${namespace}" exec \
      deployment/execution-foreman-execution-proxy -- \
      sh -c 'cat /var/lib/foreman-proxy/recovery-probe'
  )"
  if [[ "${actual_value}" != "${expected_value}" ]]; then
    echo "Execution proxy recovery probe is '${actual_value}', expected '${expected_value}'" >&2
    exit 1
  fi
}

assert_ansible_content_revision() {
  local expected_revision="$1"

  kubectl --namespace "${namespace}" exec \
    deployment/execution-foreman-execution-proxy -- \
    grep -Fxq \
      "foreman_kubernetes_content_revision: \"${expected_revision}\"" \
      /etc/ansible/roles/foreman_kubernetes_test/defaults/main.yml
}

assert_shared_foreman_tmp() {
  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    sh -c 'printf "%s\n" shared-between-pods > /usr/share/foreman/tmp/shared-volume-probe'

  # The command substitution intentionally runs inside the worker container.
  # shellcheck disable=SC2016
  kubectl --namespace "${namespace}" exec "$(dynflow_worker_pod)" -- \
    sh -c 'test "$(cat /usr/share/foreman/tmp/shared-volume-probe)" = shared-between-pods && rm /usr/share/foreman/tmp/shared-volume-probe'
}

set_secret_probe() {
  local expected_value="$1"

  kubectl --namespace "${namespace}" create secret generic recovery-probe \
    --from-literal="value=${expected_value}" \
    --dry-run=client \
    --output=yaml | kubectl apply --filename=-
}

assert_secret_probe() {
  local expected_value="$1"
  local actual_value

  actual_value="$(
    kubectl --namespace "${namespace}" get secret recovery-probe \
      --output=jsonpath='{.data.value}' | openssl base64 -d -A
  )"
  if [[ "${actual_value}" != "${expected_value}" ]]; then
    echo "Secret recovery probe is '${actual_value}', expected '${expected_value}'" >&2
    exit 1
  fi
}

assert_database_probes_absent() {
  local actual_value
  local database

  for database in foreman candlepin pulp; do
    actual_value="$(
      kubectl --namespace "${namespace}" exec deployment/postgresql -- \
        env "PGPASSWORD=${database}-test" \
        psql \
        --host=127.0.0.1 \
        --username="${database}" \
        --dbname="${database}" \
        --tuples-only \
        --no-align \
        --command="SELECT to_regclass('public.foreman_kubernetes_recovery_probe') IS NULL"
    )"
    if [[ "${actual_value}" != t ]]; then
      echo "${database} was not reset before the clean restore" >&2
      exit 1
    fi
  done
}

install_dependencies() {
  local ansible_revision="${1:-v1}"

  kubectl create namespace "${namespace}" --dry-run=client --output=yaml | kubectl apply --filename=-
  kubectl apply --filename="${repo_root}/tests/kind/dependencies.yaml"
  kubectl --namespace "${namespace}" rollout status deployment/postgresql --timeout=5m
  kubectl --namespace "${namespace}" rollout status deployment/valkey --timeout=5m
  kubectl --namespace "${namespace}" rollout status deployment/artemis --timeout=5m
  kubectl --namespace "${namespace}" rollout status deployment/content-source --timeout=5m
  "${repo_root}/tests/kind/apply-secrets.sh" "${temporary_directory}"
  kubectl apply --filename="${repo_root}/tests/kind/execution-target.yaml"
  "${repo_root}/tests/kind/publish-ansible-content.sh" "${ansible_revision}"
  kubectl --namespace "${namespace}" rollout status deployment/execution-target --timeout=5m
  kubectl label namespace "${namespace}" \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/enforce-version=v1.34 \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/audit-version=v1.34 \
    pod-security.kubernetes.io/warn=restricted \
    pod-security.kubernetes.io/warn-version=v1.34 \
    --overwrite >/dev/null
}

configure_cluster_dns() {
  local rewrite='rewrite name exact foreman.test ingress-nginx-controller.ingress-nginx.svc.cluster.local'

  if kubectl --namespace kube-system get configmap coredns \
    --output=jsonpath='{.data.Corefile}' | grep -Fq "${rewrite}"; then
    return
  fi

  kubectl --namespace kube-system get configmap coredns --output=json | \
    jq --arg rewrite "${rewrite}" \
      '.data.Corefile |= sub("(?m)^    ready$"; "    ready\n    " + $rewrite)' | \
    kubectl apply --filename=-

  kubectl --namespace kube-system get configmap coredns \
    --output=jsonpath='{.data.Corefile}' | grep -Fq "${rewrite}"
  kubectl --namespace kube-system rollout restart deployment/coredns
  kubectl --namespace kube-system rollout status deployment/coredns --timeout=5m
}

assert_execution_plane() {
  local role_revision="${1:-v1}"
  local test_proxy_interruption="${2:-0}"

  EXPECTED_ROLE_REVISION="${role_revision}" \
    TEST_PROXY_INTERRUPTION="${test_proxy_interruption}" \
    "${repo_root}/tests/kind/execution-plane.sh" "${temporary_directory}"
}

start_execution_upgrade_job() {
  local upgrade_name="$1"
  local state_file="$2"

  EXECUTION_SCENARIO=start-upgrade \
    EXECUTION_UPGRADE_NAME="${upgrade_name}" \
    EXECUTION_STATE_FILE="${state_file}" \
    "${repo_root}/tests/kind/execution-plane.sh" "${temporary_directory}"
}

finish_execution_upgrade_job() {
  local upgrade_name="$1"
  local state_file="$2"

  EXECUTION_SCENARIO=finish-upgrade \
    EXECUTION_UPGRADE_NAME="${upgrade_name}" \
    EXECUTION_STATE_FILE="${state_file}" \
    "${repo_root}/tests/kind/execution-plane.sh" "${temporary_directory}"
}

restore_foreman_database_url() {
  [[ -n "${foreman_database_url_backup}" ]] || return 0

  kubectl --namespace "${namespace}" patch secret foreman-runtime \
    --type=merge \
    --patch "$(jq --compact-output --null-input \
      --arg database_url "${foreman_database_url_backup}" \
      '{data: {DATABASE_URL: $database_url}}')" >/dev/null
  foreman_database_url_backup=""
}

restore_candlepin_database_password() {
  [[ -n "${candlepin_database_password_backup}" ]] || return 0

  kubectl --namespace "${namespace}" patch secret candlepin-runtime \
    --type=merge \
    --patch "$(jq --compact-output --null-input \
      --arg database_password "${candlepin_database_password_backup}" \
      '{data: {"database-password": $database_password}}')" >/dev/null
  candlepin_database_password_backup=""
}

assert_failed_migration_gate() {
  local upgrade_state="${temporary_directory}/failed-migration-upgrade.json"
  local application_workload_uids_before
  local candlepin_uids_before
  local wrong_database_password
  local wrong_database_url
  local foreman_uids_before
  local dynflow_orchestrator_uids_before
  local dynflow_worker_uids_before
  local dynflow_hosts_queue_uids_before
  local helm_revision_before

  application_workload_uids_before="$(application_workload_pod_uids)"
  candlepin_uids_before="$(pod_uids 'app.kubernetes.io/component=candlepin')"
  foreman_uids_before="$(pod_uids 'app.kubernetes.io/component=foreman')"
  dynflow_orchestrator_uids_before="$(pod_uids 'app.kubernetes.io/component=dynflow-orchestrator')"
  dynflow_worker_uids_before="$(pod_uids 'app.kubernetes.io/component=dynflow-worker')"
  dynflow_hosts_queue_uids_before="$(pod_uids 'app.kubernetes.io/component=dynflow-worker-hosts-queue')"
  helm_revision_before="$(helm status "${release}" --namespace "${namespace}" --output=json | jq --raw-output '.version')"
  start_execution_upgrade_job failed-migration-upgrade "${upgrade_state}"

  foreman_database_url_backup="$(kubectl --namespace "${namespace}" get secret \
    foreman-runtime --output=jsonpath='{.data.DATABASE_URL}')"
  wrong_database_url="$(printf '%s' \
    'postgresql://foreman:wrong-password@postgresql:5432/foreman' | openssl base64 -A)"
  kubectl --namespace "${namespace}" patch secret foreman-runtime \
    --type=merge \
    --patch "$(jq --compact-output --null-input \
      --arg database_url "${wrong_database_url}" \
      '{data: {DATABASE_URL: $database_url}}')" >/dev/null

  if helm_apply \
    --set foreman.dynflow.workerConcurrency=4 \
    --set migrations.activeDeadlineSeconds=90 \
    --timeout 5m; then
    restore_foreman_database_url
    echo 'Application upgrade unexpectedly succeeded with invalid Foreman database credentials' >&2
    exit 1
  fi

  helm status "${release}" --namespace "${namespace}" --output=json | \
    jq --exit-status --argjson revision "${helm_revision_before}" \
      '.info.status == "deployed" and .version == $revision' >/dev/null
  kubectl --namespace "${namespace}" get jobs \
    --selector=app.kubernetes.io/component=foreman-migrate \
    --output=json | jq --exit-status \
      'sort_by(.metadata.creationTimestamp) | last |
       ((.status.failed // 0) >= 1 or
        any(.status.conditions[]?; .type == "Failed" and .status == "True"))' >/dev/null
  restore_foreman_database_url

  assert_application_workloads_unchanged "${application_workload_uids_before}"
  assert_pods_unchanged 'app.kubernetes.io/component=foreman' "${foreman_uids_before}"
  assert_pods_unchanged \
    'app.kubernetes.io/component=dynflow-orchestrator' \
    "${dynflow_orchestrator_uids_before}"
  assert_pods_unchanged 'app.kubernetes.io/component=dynflow-worker' "${dynflow_worker_uids_before}"
  assert_pods_unchanged \
    'app.kubernetes.io/component=dynflow-worker-hosts-queue' \
    "${dynflow_hosts_queue_uids_before}"
  assert_foreman_ready

  candlepin_java_xms=544m
  candlepin_database_password_backup="$(kubectl --namespace "${namespace}" get secret \
    candlepin-runtime --output=jsonpath='{.data.database-password}')"
  wrong_database_password="$(printf '%s' 'wrong-password' | openssl base64 -A)"
  kubectl --namespace "${namespace}" patch secret candlepin-runtime \
    --type=merge \
    --patch "$(jq --compact-output --null-input \
      --arg database_password "${wrong_database_password}" \
      '{data: {"database-password": $database_password}}')" >/dev/null

  if helm_apply \
    --set foreman.dynflow.workerConcurrency=4 \
    --set migrations.activeDeadlineSeconds=90 \
    --timeout 5m; then
    restore_candlepin_database_password
    echo 'Application upgrade unexpectedly succeeded with invalid Candlepin database credentials' >&2
    exit 1
  fi

  helm status "${release}" --namespace "${namespace}" --output=json | \
    jq --exit-status --argjson revision "${helm_revision_before}" \
      '.info.status == "deployed" and .version == $revision' >/dev/null
  kubectl --namespace "${namespace}" get jobs \
    --selector=app.kubernetes.io/component=candlepin-migrate \
    --output=json | jq --exit-status \
      'sort_by(.metadata.creationTimestamp) | last |
       any(.status.conditions[]?; .type == "Failed" and .status == "True")' >/dev/null
  restore_candlepin_database_password

  assert_application_workloads_unchanged "${application_workload_uids_before}"
  assert_candlepin_ha
  assert_foreman_ready
  finish_execution_upgrade_job failed-migration-upgrade "${upgrade_state}"
  assert_application_smoke_test

  helm_apply --set foreman.dynflow.workerConcurrency=4
  assert_pods_replaced 'app.kubernetes.io/component=foreman' "${foreman_uids_before}"
  assert_pods_replaced \
    'app.kubernetes.io/component=dynflow-orchestrator' \
    "${dynflow_orchestrator_uids_before}"
  assert_pods_replaced 'app.kubernetes.io/component=dynflow-worker' "${dynflow_worker_uids_before}"
  assert_pods_replaced \
    'app.kubernetes.io/component=dynflow-worker-hosts-queue' \
    "${dynflow_hosts_queue_uids_before}"
  assert_pods_replaced 'app.kubernetes.io/component=candlepin' "${candlepin_uids_before}"
  assert_candlepin_ha
  assert_foreman_ready
  assert_application_smoke_test
}

rotate_execution_identity() {
  local rotated_prefix="${temporary_directory}/execution-rotated"

  ssh-keygen -q -t ed25519 -N '' \
    -C foreman-kubernetes-rotated \
    -f "${rotated_prefix}-ssh"
  if cmp -s \
    "${temporary_directory}/id_ed25519_foreman_proxy.pub" \
    "${rotated_prefix}-ssh.pub"; then
    echo 'Rotated SSH public key unexpectedly matches the original key' >&2
    exit 1
  fi

  openssl req -new -newkey rsa:2048 -nodes \
    -subj '/CN=execution-foreman-execution-proxy' \
    -keyout "${rotated_prefix}-server.key" \
    -out "${rotated_prefix}-server.csr" >/dev/null 2>&1
  openssl x509 -req -sha256 -days 7 \
    -in "${rotated_prefix}-server.csr" \
    -CA "${temporary_directory}/ca.crt" \
    -CAkey "${temporary_directory}/ca.key" \
    -CAcreateserial \
    -extfile <(printf '%s\n' \
      'subjectAltName=DNS:execution-foreman-execution-proxy,DNS:execution-foreman-execution-proxy.foreman,DNS:execution-foreman-execution-proxy.foreman.svc' \
      'extendedKeyUsage=serverAuth') \
    -out "${rotated_prefix}-server.crt" >/dev/null 2>&1

  openssl req -new -newkey rsa:2048 -nodes \
    -subj '/CN=foreman.test' \
    -keyout "${rotated_prefix}-client.key" \
    -out "${rotated_prefix}-client.csr" >/dev/null 2>&1
  openssl x509 -req -sha256 -days 7 \
    -in "${rotated_prefix}-client.csr" \
    -CA "${temporary_directory}/ca.crt" \
    -CAkey "${temporary_directory}/ca.key" \
    -CAcreateserial \
    -extfile <(printf 'extendedKeyUsage=clientAuth\n') \
    -out "${rotated_prefix}-client.crt" >/dev/null 2>&1

  openssl verify \
    -CAfile "${temporary_directory}/ca.crt" \
    -purpose sslserver \
    "${rotated_prefix}-server.crt" >/dev/null
  openssl verify \
    -CAfile "${temporary_directory}/ca.crt" \
    -purpose sslclient \
    "${rotated_prefix}-client.crt" >/dev/null

  kubectl --namespace "${namespace}" create secret generic foreman-execution-proxy-tls \
    --from-file=ca.crt="${temporary_directory}/ca.crt" \
    --from-file=tls.crt="${rotated_prefix}-server.crt" \
    --from-file=tls.key="${rotated_prefix}-server.key" \
    --dry-run=client --output=yaml | kubectl apply --filename=-
  kubectl --namespace "${namespace}" create secret generic foreman-execution-proxy-foreman-client \
    --from-file=ca.crt="${temporary_directory}/ca.crt" \
    --from-file=tls.crt="${rotated_prefix}-client.crt" \
    --from-file=tls.key="${rotated_prefix}-client.key" \
    --dry-run=client --output=yaml | kubectl apply --filename=-
  kubectl --namespace "${namespace}" create secret generic foreman-execution-proxy-ssh \
    --from-file=id_rsa_foreman_proxy="${rotated_prefix}-ssh" \
    --from-file=id_rsa_foreman_proxy.pub="${rotated_prefix}-ssh.pub" \
    --dry-run=client --output=yaml | kubectl apply --filename=-

  execution_secret_rollout_token=rotated-identity-1
  kubectl --namespace "${namespace}" rollout restart \
    deployment/execution-target
  helm_execution_apply
  kubectl --namespace "${namespace}" rollout status \
    deployment/execution-target \
    --timeout=5m
  kubectl --namespace "${namespace}" rollout status \
    deployment/execution-foreman-execution-proxy \
    --timeout=10m
}

reset_namespace_for_restore() {
  local kind_node="${cluster_name}-control-plane"

  kubectl delete namespace "${namespace}" --wait=true
  kubectl delete persistentvolume \
    foreman-kind-pulp-data \
    foreman-kind-tmp \
    foreman-kind-avatars \
    foreman-kind-object-storage \
    foreman-kind-recovery-repository \
    --ignore-not-found=true \
    --wait=true

  docker exec "${kind_node}" \
    find /var/local/foreman-kind-pulp \
    -mindepth 1 \
    -maxdepth 1 \
    -exec rm -rf -- '{}' +
  docker exec "${kind_node}" \
    find /var/local/foreman-kind-tmp \
    -mindepth 1 \
    -maxdepth 1 \
    -exec rm -rf -- '{}' +
  docker exec "${kind_node}" \
    find /var/local/foreman-kind-avatars \
    -mindepth 1 \
    -maxdepth 1 \
    -exec rm -rf -- '{}' +
  docker exec "${kind_node}" \
    find /var/local/foreman-kind-object-storage \
    -mindepth 1 \
    -maxdepth 1 \
    -exec rm -rf -- '{}' +
  docker exec "${kind_node}" test -f /var/local/foreman-kind-recovery/config

  install_dependencies v2
  set_secret_probe after-reset
  assert_secret_probe after-reset
  assert_database_probes_absent
  docker exec "${kind_node}" test ! -e /var/local/foreman-kind-pulp/recovery-probe
  docker exec "${kind_node}" test ! -e /var/local/foreman-kind-avatars/recovery-probe
}

cleanup() {
  local exit_status=$?
  if [[ -n "${foreman_database_url_backup}" ]] && \
    kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    restore_foreman_database_url || true
  fi
  if [[ -n "${candlepin_database_password_backup}" ]] && \
    kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    restore_candlepin_database_password || true
  fi
  if [[ ${exit_status} -ne 0 ]] && kubectl get namespace "${namespace}" >/dev/null 2>&1; then
    kubectl --namespace "${namespace}" get pods,jobs
  fi
  rm -rf "${temporary_directory}"
  if [[ "${created_cluster}" == true && "${KEEP_CLUSTER:-0}" != 1 ]]; then
    kind delete cluster --name "${cluster_name}"
  fi
  exit "${exit_status}"
}
trap cleanup EXIT

for command_name in kind kubectl helm openssl curl jq docker ssh-keygen cmp ruby; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "${command_name} is required" >&2
    exit 1
  fi
done

if [[ -n "${image_profile}" && -z "${execution_proxy_image_profile}" ]] ||
  [[ -z "${image_profile}" && -n "${execution_proxy_image_profile}" ]]; then
  echo 'IMAGE_PROFILE and EXECUTION_PROXY_IMAGE_PROFILE must be overridden together' >&2
  exit 1
fi
if [[ -n "${image_profile}" ]]; then
  recovery_application_profile_override="${image_profile}"
  recovery_execution_profile_override="${execution_proxy_image_profile}"
fi

if [[ -z "${compatibility_set}" ]]; then
  compatibility_set="$(jq --exit-status --raw-output '.default' \
    "${compatibility_sets_file}")"
fi
if ! jq --exit-status --arg set "${compatibility_set}" \
  '.sets[$set]' "${compatibility_sets_file}" >/dev/null; then
  echo "unknown compatibility set: ${compatibility_set}" >&2
  exit 1
fi
if [[ "$(jq --exit-status --raw-output \
  --arg set "${compatibility_set}" '.sets[$set].status' \
  "${compatibility_sets_file}")" == candidate ]]; then
  recovery_allow_candidate=1
fi

if [[ -z "${image_profile}" ]]; then
  image_profile="${repo_root}/$(jq --exit-status --raw-output \
    --arg set "${compatibility_set}" '.sets[$set].applicationProfile' \
    "${compatibility_sets_file}")"
  execution_proxy_image_profile="${repo_root}/$(jq --exit-status --raw-output \
    --arg set "${compatibility_set}" '.sets[$set].executionProxyProfile' \
    "${compatibility_sets_file}")"
fi

if [[ ! -f "${image_profile}" ]]; then
  echo "image profile does not exist: ${image_profile}" >&2
  exit 1
fi

if [[ ! -f "${execution_proxy_image_profile}" ]]; then
  echo "execution proxy image profile does not exist: ${execution_proxy_image_profile}" >&2
  exit 1
fi

if [[ "$(uname -m)" != x86_64 && "$(uname -m)" != amd64 && "${ALLOW_EMULATION:-0}" != 1 ]]; then
  echo "Foreman, Candlepin, and Pulp images are currently linux/amd64 only." >&2
  echo "Run this test on amd64 or set ALLOW_EMULATION=1 to accept a slower emulated run." >&2
  exit 1
fi

if kind get clusters | grep -Fxq "${cluster_name}"; then
  if [[ "${REUSE_CLUSTER:-0}" != 1 ]]; then
    echo "kind cluster ${cluster_name} already exists; set REUSE_CLUSTER=1 to use it" >&2
    exit 1
  fi
else
  kind create cluster \
    --name "${cluster_name}" \
    --config "${repo_root}/tests/kind/kind-config.yaml" \
    --image "${kind_node_image}"
  created_cluster=true
fi

if [[ "${skip_recovery_test}" != 1 ]]; then
  docker build \
    --file "${repo_root}/images/recovery-toolbox/Dockerfile" \
    --tag foreman-kubernetes-recovery-toolbox:test \
    "${repo_root}"
  kind load docker-image \
    --name "${cluster_name}" \
    foreman-kubernetes-recovery-toolbox:test
fi

docker build \
  --file "${repo_root}/images/ssh-target/Dockerfile" \
  --tag foreman-kubernetes-ssh-target:test \
  "${repo_root}"
kind load docker-image \
  --name "${cluster_name}" \
  foreman-kubernetes-ssh-target:test

docker build \
  --file "${repo_root}/images/release-operator/Dockerfile" \
  --tag foreman-release-operator:test \
  "${repo_root}"
kind load docker-image \
  --name "${cluster_name}" \
  foreman-release-operator:test

helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  --wait \
  --timeout 10m

configure_cluster_dns

install_dependencies

helm_apply
helm_execution_apply

kubectl --namespace "${namespace}" wait \
  --for=condition=complete \
  job \
  --selector=app.kubernetes.io/component=pulp-registration \
  --timeout=10m

assert_foreman_ready
assert_shared_foreman_tmp
assert_candlepin_ha
assert_candlepin_pod_recovery
assert_application_smoke_test

ruby "${repo_root}/tests/kind/image-runtime-contract.rb" \
  "${namespace}" \
  "${image_profile}" \
  "${execution_proxy_image_profile}" \
  "${image_runtime_contract_file}"

NAMESPACE="${namespace}" \
  COMPATIBILITY_SET="${compatibility_set}" \
  IMAGE_PROFILE="${image_profile}" \
  PULP_OBJECT_STORAGE_EVIDENCE_FILE="${pulp_object_storage_evidence_file}" \
  "${repo_root}/tests/kind/object-storage.sh"

pulp_api_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --cacert "${temporary_directory}/ca.crt" \
  --resolve content.test:8443:127.0.0.1 \
  https://content.test:8443/pulp/api/v3/status/)"
if [[ "${pulp_api_status}" != 404 ]]; then
  echo "public Pulp API returned ${pulp_api_status}, expected 404" >&2
  exit 1
fi

assert_pulp_registration
assert_execution_plane v1 1
"${repo_root}/tests/kind/content-lifecycle.sh" \
  seed "${temporary_directory}" "${content_lifecycle_state}"
NAMESPACE="${namespace}" "${repo_root}/tests/kind/candlepin-job-delivery.sh" \
  "${candlepin_job_delivery_file}"

if [[ "${skip_recovery_test}" != 1 ]]; then
  set_database_probes before-backup
  set_pulp_probe before-backup
  set_avatar_probe before-backup
  set_execution_state_probe before-backup
  assert_ansible_content_revision v1
  assert_secret_probe before-backup

  run_recovery backup e2e-backup

  set_database_probes after-backup
  set_pulp_probe after-backup
  set_avatar_probe after-backup
  set_secret_probe after-backup
  assert_database_probes after-backup
  assert_pulp_probe after-backup
  assert_avatar_probe after-backup
  assert_execution_state_probe before-backup
  assert_ansible_content_revision v1
  assert_secret_probe after-backup

  reset_namespace_for_restore

  run_recovery restore e2e-restore

  assert_foreman_ready
  assert_candlepin_ha
  assert_pulp_registration
  assert_application_smoke_test
  "${repo_root}/tests/kind/content-lifecycle.sh" \
    assert "${temporary_directory}" "${content_lifecycle_state}"
  assert_database_probes before-backup
  assert_pulp_probe before-backup
  assert_avatar_probe before-backup
  assert_execution_state_probe before-backup
  assert_ansible_content_revision v1
  assert_secret_probe before-backup
  assert_execution_plane
fi

assert_failed_migration_gate

kubectl --namespace "${namespace}" scale \
  deployment/foreman-foreman-stack-dynflow-worker \
  --replicas=2
kubectl --namespace "${namespace}" rollout status \
  deployment/foreman-foreman-stack-dynflow-worker \
  --timeout=10m

application_upgrade_state="${temporary_directory}/application-upgrade.json"
foreman_uids_before="$(pod_uids 'app.kubernetes.io/component=foreman')"
dynflow_orchestrator_uids_before="$(pod_uids 'app.kubernetes.io/component=dynflow-orchestrator')"
dynflow_worker_uids_before="$(pod_uids 'app.kubernetes.io/component=dynflow-worker')"
dynflow_hosts_queue_uids_before="$(pod_uids 'app.kubernetes.io/component=dynflow-worker-hosts-queue')"
start_execution_upgrade_job application-upgrade "${application_upgrade_state}"
helm_apply \
  --set foreman.dynflow.workers=2 \
  --set foreman.dynflow.workerConcurrency=3

kubectl --namespace "${namespace}" rollout status \
  deployment/foreman-foreman-stack-foreman \
  --timeout=10m
assert_pods_replaced 'app.kubernetes.io/component=foreman' "${foreman_uids_before}"
assert_pods_replaced \
  'app.kubernetes.io/component=dynflow-orchestrator' \
  "${dynflow_orchestrator_uids_before}"
assert_pods_replaced 'app.kubernetes.io/component=dynflow-worker' "${dynflow_worker_uids_before}"
assert_pods_replaced \
  'app.kubernetes.io/component=dynflow-worker-hosts-queue' \
  "${dynflow_hosts_queue_uids_before}"
finish_execution_upgrade_job application-upgrade "${application_upgrade_state}"

assert_application_smoke_test

proxy_upgrade_state="${temporary_directory}/proxy-upgrade.json"
execution_proxy_uids_before="$(pod_uids 'app.kubernetes.io/instance=execution,app.kubernetes.io/component=execution-proxy')"
start_execution_upgrade_job proxy-upgrade "${proxy_upgrade_state}"
helm_execution_apply --set proxy.logLevel=DEBUG
assert_pods_replaced \
  'app.kubernetes.io/instance=execution,app.kubernetes.io/component=execution-proxy' \
  "${execution_proxy_uids_before}"
finish_execution_upgrade_job proxy-upgrade "${proxy_upgrade_state}"

rotate_execution_identity
assert_execution_plane
"${repo_root}/tests/kind/publish-ansible-content.sh" v2
assert_execution_plane v2
NAMESPACE="${namespace}" \
  COMPATIBILITY_SET="${compatibility_set}" \
  OPERATOR_RELEASE_EVIDENCE_FILE="${operator_release_evidence_file}" \
  "${repo_root}/tests/kind/operator-release.sh" \
    "${temporary_directory}/operator-release"
assert_execution_plane v2
write_integration_evidence

if [[ "${skip_recovery_test}" == 1 ]]; then
  echo "Kind install, Candlepin HA, mTLS, content replacement, execution, proxy restart, scale, and upgrade checks passed; recovery drill skipped."
else
  echo "Kind install, Candlepin HA, mTLS, content replacement, execution, proxy restart, backup, restore, scale, and upgrade checks passed."
fi
