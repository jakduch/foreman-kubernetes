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

  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    env "TASK_ID=${task_id}" bin/rails runner '
      task = ForemanTasks::Task.find(ENV.fetch("TASK_ID"))
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 600
      loop do
        task.reload
        if task.stopped?
          abort "Task #{task.id} (#{task.label}) ended with #{task.result}" unless task.result == "success"
          puts "Task #{task.id} (#{task.label}) succeeded"
          break
        end
        abort "Timed out waiting for task #{task.id} (#{task.label})" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 2
      end
    '
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

run_job() {
  local marker="$1"
  local provider="$2"
  local proxy_id="$3"
  local template_id="${4:-}"
  local invocation
  local invocation_id
  local selected_proxy_id
  local task_id
  local payload

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    rm -f "/tmp/${marker}"

  if [[ "${provider}" == Script ]]; then
    payload="$(jq --compact-output --null-input \
      --arg command "touch /tmp/${marker}" \
      --arg search_query "name = \"${target_name}\"" '{
        job_invocation: {
          feature: "run_script",
          inputs: {command: $command},
          search_query: $search_query,
          targeting_type: "static_query",
          ssh_user: "foreman"
        }
      }')"
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
  fi

  invocation="$(foreman_api POST '/api/job_invocations?include_hosts=false' "${payload}")"
  invocation_id="$(jq --exit-status --raw-output '.id' <<<"${invocation}")"
  task_id="$(jq --exit-status --raw-output '.dynflow_task.id' <<<"${invocation}")"
  wait_for_task "${task_id}"

  kubectl --namespace "${namespace}" exec deployment/execution-target -- \
    test -f "/tmp/${marker}"

  selected_proxy_id="$(foreman_api GET "/api/job_invocations/${invocation_id}/hosts?per_page=all" | \
    jq --exit-status --raw-output '.results[0].smart_proxy_id')"
  if [[ "${selected_proxy_id}" != "${proxy_id}" ]]; then
    echo "${provider} job used Smart Proxy ${selected_proxy_id}, expected ${proxy_id}" >&2
    exit 1
  fi
}

organization_id="$(default_taxonomy_id organizations)"
location_id="$(default_taxonomy_id locations)"
proxy_id="$(register_execution_proxy "${location_id}" "${organization_id}")"
ensure_target_host "${location_id}" "${organization_id}" >/dev/null

ansible_template_id="$(foreman_api GET '/api/job_templates?per_page=all' | \
  exact_result_id 'Run Command - Ansible Default')"

run_job foreman-kubernetes-rex-ok Script "${proxy_id}"
run_job foreman-kubernetes-ansible-ok Ansible "${proxy_id}" "${ansible_template_id}"

echo "Execution proxy registration, feature boundary, SSH job, and Ansible job checks passed."
