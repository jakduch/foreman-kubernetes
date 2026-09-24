#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 TEMPORARY_DIRECTORY" >&2
  exit 2
fi

temporary_directory="$1"
namespace="foreman"
proxy_name="Kubernetes execution proxy"
proxy_url="https://execution-foreman-execution-proxy:8443"
target_name="execution-target.foreman.svc.cluster.local"
role_name="foreman_kubernetes_test"

foreman_pod() {
  kubectl --namespace "${namespace}" get pod \
    --selector=app.kubernetes.io/component=foreman \
    --output=jsonpath='{.items[0].metadata.name}'
}

foreman_api() {
  local method="$1"
  local path="$2"
  local payload="${3:-}"
  local -a curl_args=(
    --fail-with-body
    --silent
    --show-error
    --cacert "${temporary_directory}/ca.crt"
    --resolve foreman.test:8443:127.0.0.1
    --user admin:foreman-test
    --request "${method}"
    --header 'Accept: application/json'
    --header 'Content-Type: application/json'
  )

  if [[ -n "${payload}" ]]; then
    curl_args+=(--data "${payload}")
  fi

  curl "${curl_args[@]}" "https://foreman.test:8443${path}"
}

wait_for_task() {
  local task_id="$1"
  local expected_result="${2:-success}"

  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    env "TASK_ID=${task_id}" "EXPECTED_RESULT=${expected_result}" bin/rails runner '
      task = ForemanTasks::Task.find(ENV.fetch("TASK_ID"))
      expected = ENV.fetch("EXPECTED_RESULT")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 600
      loop do
        task.reload
        if task.stopped?
          valid = case expected
                  when "success" then task.result == "success"
                  when "error" then task.result == "error"
                  when "not-success" then task.result != "success"
                  else false
                  end
          abort "Task #{task.id} (#{task.label}) ended with #{task.result}, expected #{expected}" unless valid
          puts "Task #{task.id} (#{task.label}) ended with expected result #{task.result}"
          break
        end
        abort "Timed out waiting for task #{task.id} (#{task.label})" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 2
      end
    '
}

create_script_job() {
  local command="$1"

  foreman_api POST '/api/job_invocations?include_hosts=false' "$(
    jq --compact-output --null-input \
      --arg command "${command}" \
      --arg search_query "name = \"${target_name}\"" '{
        job_invocation: {
          feature: "run_script",
          inputs: {command: $command},
          search_query: $search_query,
          targeting_type: "static_query",
          ssh_user: "foreman"
        }
      }'
  )"
}

assert_job_proxy() {
  local invocation_id="$1"
  local provider="$2"
  local proxy_id="$3"
  local selected_proxy_id

  selected_proxy_id="$(foreman_api GET "/api/job_invocations/${invocation_id}/hosts?per_page=all" | \
    jq --exit-status --raw-output '.results[0].smart_proxy_id')"
  if [[ "${selected_proxy_id}" != "${proxy_id}" ]]; then
    echo "${provider} job used Smart Proxy ${selected_proxy_id}, expected ${proxy_id}" >&2
    exit 1
  fi
}

wait_for_job_proxy() {
  local invocation_id="$1"
  local proxy_id="$2"
  local selected_proxy_id

  for _ in $(seq 1 120); do
    selected_proxy_id="$(
      foreman_api GET "/api/job_invocations/${invocation_id}/hosts?per_page=all" | \
        jq --raw-output '.results[0].smart_proxy_id // empty'
    )"
    if [[ "${selected_proxy_id}" == "${proxy_id}" ]]; then
      return
    fi
    sleep 1
  done

  echo "Job ${invocation_id} was not dispatched through Smart Proxy ${proxy_id}" >&2
  exit 1
}

assert_egress_boundary() {
  local proxy_deployment="deployment/execution-foreman-execution-proxy"

  kubectl --namespace "${namespace}" exec "${proxy_deployment}" -- \
    ruby -rsocket -e 'Socket.tcp("foreman.test", 443, connect_timeout: 5).close'
  kubectl --namespace "${namespace}" exec "${proxy_deployment}" -- \
    ruby -rsocket -e 'Socket.tcp("execution-target", 22, connect_timeout: 5).close'

  if kubectl --namespace "${namespace}" exec "${proxy_deployment}" -- \
    ruby -rsocket -e 'Socket.tcp("content-source", 80, connect_timeout: 3).close' \
    >/dev/null 2>&1; then
    echo 'Execution proxy reached an undeclared in-cluster destination' >&2
    exit 1
  fi
}

first_result_id() {
  jq --exit-status --raw-output '.results[0].id'
}

exact_result_id() {
  local name="$1"

  jq --exit-status --raw-output --arg name "${name}" \
    'first(.results[] | select(.name == $name)) | .id'
}

default_taxonomy_id() {
  local endpoint="$1"

  foreman_api GET "/api/${endpoint}?per_page=all" | first_result_id
}

register_execution_proxy() {
  local location_id="$1"
  local organization_id="$2"
  local proxy
  local proxy_id
  local proxies
  local features

  proxies="$(foreman_api GET '/api/smart_proxies?per_page=all')"
  proxy_id="$(exact_result_id "${proxy_name}" <<<"${proxies}" || true)"

  if [[ -z "${proxy_id}" ]]; then
    proxy="$(foreman_api POST /api/smart_proxies "$(
      jq --compact-output --null-input \
        --arg name "${proxy_name}" \
        --arg url "${proxy_url}" \
        --argjson organization_id "${organization_id}" \
        --argjson location_id "${location_id}" '{
          smart_proxy: {
            name: $name,
            url: $url,
            organization_ids: [$organization_id],
            location_ids: [$location_id]
          }
        }'
    )")"
    proxy_id="$(jq --exit-status --raw-output '.id' <<<"${proxy}")"
  else
    foreman_api PUT "/api/smart_proxies/${proxy_id}" "$(
      jq --compact-output --null-input \
        --arg url "${proxy_url}" \
        --argjson organization_id "${organization_id}" \
        --argjson location_id "${location_id}" '{
          smart_proxy: {
            url: $url,
            organization_ids: [$organization_id],
            location_ids: [$location_id]
          }
        }'
    )" >/dev/null
  fi

  foreman_api PUT "/api/smart_proxies/${proxy_id}/refresh" '{}' >/dev/null
  proxy="$(foreman_api GET "/api/smart_proxies/${proxy_id}")"
  features="$(jq --exit-status --raw-output \
    '[.features[].name] | sort | join(",")' <<<"${proxy}")"
  if [[ "${features}" != "Ansible,Dynflow,Script" ]]; then
    echo "Execution proxy features are '${features}', expected 'Ansible,Dynflow,Script'" >&2
    exit 1
  fi

  printf '%s\n' "${proxy_id}"
}

ensure_target_host() {
  local location_id="$1"
  local organization_id="$2"
  local host_id
  local hosts

  hosts="$(foreman_api GET '/api/hosts?per_page=all')"
  host_id="$(exact_result_id "${target_name}" <<<"${hosts}" || true)"
  if [[ -n "${host_id}" ]]; then
    printf '%s\n' "${host_id}"
    return
  fi

  foreman_api POST /api/hosts "$(
    jq --compact-output --null-input \
      --arg name "${target_name}" \
      --argjson organization_id "${organization_id}" \
      --argjson location_id "${location_id}" '{
        host: {
          name: $name,
          managed: false,
          build: false,
          organization_id: $organization_id,
          location_id: $location_id
        }
      }'
  )" | jq --exit-status --raw-output '.id'
}

configure_execution_defaults() {
  foreman_api PUT /api/settings/remote_execution_ssh_user \
    '{"setting":{"value":"foreman"}}' >/dev/null
}

sync_ansible_role() {
  local proxy_id="$1"
  local available_roles
  local role_id
  local sync_response
  local task_id

  available_roles="$(foreman_api GET "/ansible/api/v2/ansible_roles/fetch?proxy_id=${proxy_id}")"
  if ! jq --exit-status --arg role_name "${role_name}" \
    '.results.ansible_roles[] | select(.name == $role_name)' \
    <<<"${available_roles}" >/dev/null; then
    echo "Ansible role ${role_name} is not visible through Smart Proxy ${proxy_id}" >&2
    exit 1
  fi

  sync_response="$(foreman_api PUT /ansible/api/v2/ansible_roles/sync "$(
    jq --compact-output --null-input \
      --argjson proxy_id "${proxy_id}" \
      --arg role_name "${role_name}" '{
        proxy_id: $proxy_id,
        role_names: [$role_name]
      }'
  )")"
  task_id="$(jq --raw-output '.id // empty' <<<"${sync_response}")"
  if [[ -n "${task_id}" ]]; then
    wait_for_task "${task_id}" >&2
  fi

  role_id="$(foreman_api GET '/ansible/api/v2/ansible_roles?per_page=all' | \
    exact_result_id "${role_name}")"
  printf '%s\n' "${role_id}"
}

assign_ansible_role() {
  local host_id="$1"
  local role_id="$2"

  foreman_api POST "/api/hosts/${host_id}/assign_ansible_roles" "$(
    jq --compact-output --null-input \
      --argjson role_id "${role_id}" '{ansible_role_ids: [$role_id]}'
  )" >/dev/null

  foreman_api GET "/api/hosts/${host_id}/ansible_roles" | \
    jq --exit-status --arg role_name "${role_name}" \
      '.[] | select(.name == $role_name)' >/dev/null
}

run_job() {
  local marker="$1"
  local provider="$2"
  local proxy_id="$3"
  local template_id="${4:-}"
  local invocation
  local invocation_id
  local task_id
  local payload

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    rm -f "/tmp/${marker}"

  if [[ "${provider}" == Script ]]; then
    invocation="$(create_script_job "touch /tmp/${marker}")"
  else
    payload="$(jq --compact-output --null-input \
      --arg command "touch /tmp/${marker}" \
      --arg search_query "name = \"${target_name}\"" \
      --argjson template_id "${template_id}" '{
        job_invocation: {
          job_template_id: $template_id,
          inputs: {command: $command},
          search_query: $search_query,
          targeting_type: "static_query",
          ssh_user: "foreman"
        }
      }')"
    invocation="$(foreman_api POST '/api/job_invocations?include_hosts=false' "${payload}")"
  fi

  invocation_id="$(jq --exit-status --raw-output '.id' <<<"${invocation}")"
  task_id="$(jq --exit-status --raw-output '.dynflow_task.id' <<<"${invocation}")"
  wait_for_task "${task_id}"

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    test -f "/tmp/${marker}"

  assert_job_proxy "${invocation_id}" "${provider}" "${proxy_id}"
}

assert_failed_job() {
  local proxy_id="$1"
  local invocation
  local invocation_id
  local task_id

  invocation="$(create_script_job 'printf "expected failure\\n"; exit 23')"
  invocation_id="$(jq --exit-status --raw-output '.id' <<<"${invocation}")"
  task_id="$(jq --exit-status --raw-output '.dynflow_task.id' <<<"${invocation}")"
  wait_for_task "${task_id}" error

  foreman_api GET "/api/job_invocations/${invocation_id}?include_hosts=false" | \
    jq --exit-status '.failed == 1 and .succeeded == 0' >/dev/null
  assert_job_proxy "${invocation_id}" 'Expected-failure Script' "${proxy_id}"
}

assert_cancelled_job() {
  local proxy_id="$1"
  local cancellation
  local invocation
  local invocation_id
  local task_id

  invocation="$(create_script_job 'sleep 300')"
  invocation_id="$(jq --exit-status --raw-output '.id' <<<"${invocation}")"
  task_id="$(jq --exit-status --raw-output '.dynflow_task.id' <<<"${invocation}")"

  wait_for_job_proxy "${invocation_id}" "${proxy_id}"
  cancellation="$(foreman_api POST "/api/job_invocations/${invocation_id}/cancel" '{}')"
  jq --exit-status '.cancelled == true' <<<"${cancellation}" >/dev/null
  wait_for_task "${task_id}" not-success

  foreman_api GET "/api/job_invocations/${invocation_id}?include_hosts=false" | \
    jq --exit-status '.cancelled == 1 and .succeeded == 0' >/dev/null
  assert_job_proxy "${invocation_id}" 'Cancelled Script' "${proxy_id}"
}

run_role_job() {
  local host_id="$1"
  local proxy_id="$2"
  local marker="foreman-kubernetes-role-ok"
  local invocation
  local invocation_id
  local task_id

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    rm -f "/tmp/${marker}"

  invocation="$(foreman_api POST "/api/hosts/${host_id}/play_roles")"
  invocation_id="$(jq --exit-status --raw-output '.id' <<<"${invocation}")"
  task_id="$(jq --exit-status --raw-output '.dynflow_task.id' <<<"${invocation}")"
  wait_for_task "${task_id}"

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    test -f "/tmp/${marker}"

  assert_job_proxy "${invocation_id}" 'Ansible role' "${proxy_id}"
}

organization_id="$(default_taxonomy_id organizations)"
location_id="$(default_taxonomy_id locations)"
assert_egress_boundary
proxy_id="$(register_execution_proxy "${location_id}" "${organization_id}")"
host_id="$(ensure_target_host "${location_id}" "${organization_id}")"
configure_execution_defaults
role_id="$(sync_ansible_role "${proxy_id}")"
assign_ansible_role "${host_id}" "${role_id}"

ansible_template_id="$(foreman_api GET '/api/job_templates?per_page=all' | \
  exact_result_id 'Run Command - Ansible Default')"

assert_failed_job "${proxy_id}"
assert_cancelled_job "${proxy_id}"
run_job foreman-kubernetes-rex-ok Script "${proxy_id}"
run_job foreman-kubernetes-ansible-ok Ansible "${proxy_id}" "${ansible_template_id}"
run_role_job "${host_id}" "${proxy_id}"

echo "Execution proxy registration, failure/cancellation, role sync, SSH, Ansible command, and Ansible role checks passed."
