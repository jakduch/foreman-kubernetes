#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 seed|assert TEMPORARY_DIRECTORY STATE_FILE" >&2
  exit 2
fi

mode="$1"
temporary_directory="$2"
state_file="$3"
namespace="foreman"
content_filename="foreman-kubernetes-content.txt"
content_checksum="d527380869e9487a3d860b253a6aa5d454b51c419415264e90f018396e419ac5"

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
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1_800
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

task_id_from() {
  jq --exit-status --raw-output '.id // .task.id'
}

assert_equal() {
  local actual="$1"
  local expected="$2"
  local description="$3"

  if [[ "${actual}" != "${expected}" ]]; then
    echo "${description} is '${actual}', expected '${expected}'" >&2
    exit 1
  fi
}

assert_public_content() {
  local relative_path="$1"
  local download_path="${temporary_directory}/downloaded-${content_filename}"
  local downloaded_checksum
  local normalized_path

  normalized_path="${relative_path#/}"
  normalized_path="${normalized_path%/}"
  curl --fail --silent --show-error \
    --cacert "${temporary_directory}/ca.crt" \
    --resolve content.test:8443:127.0.0.1 \
    --output "${download_path}" \
    "https://content.test:8443/pulp/content/${normalized_path}/${content_filename}"

  downloaded_checksum="$(openssl dgst -sha256 -r "${download_path}" | awk '{print $1}')"
  assert_equal "${downloaded_checksum}" "${content_checksum}" "published content checksum"
}

seed_content_lifecycle() {
  local activation_key
  local activation_key_id
  local content_view
  local content_view_environment
  local content_view_environment_id
  local content_view_id
  local content_view_version
  local content_view_version_id
  local files
  local library_environment
  local library_environment_id
  local organization
  local organization_id
  local product
  local product_id
  local publish_task
  local published_repository
  local published_repository_id
  local published_relative_path
  local relative_path
  local repository
  local repository_id
  local sync_task

  organization="$(foreman_api POST /katello/api/organizations \
    '{"organization":{"name":"Kubernetes Integration","label":"Kubernetes_Integration"}}')"
  organization_id="$(jq --exit-status --raw-output '.id' <<<"${organization}")"

  product="$(foreman_api POST /katello/api/products "$(
    jq --compact-output --null-input --argjson organization_id "${organization_id}" '{
      organization_id: $organization_id,
      product: {
        name: "Kubernetes Integration Product",
        label: "Kubernetes_Integration_Product"
      }
    }'
  )")"
  product_id="$(jq --exit-status --raw-output '.id' <<<"${product}")"

  repository="$(foreman_api POST /katello/api/repositories "$(
    jq --compact-output --null-input --argjson product_id "${product_id}" '{
      product_id: $product_id,
      repository: {
        name: "Kubernetes Integration Files",
        label: "Kubernetes_Integration_Files",
        content_type: "file",
        download_policy: "immediate",
        url: "http://content-source.foreman.svc.cluster.local"
      }
    }'
  )")"
  repository_id="$(jq --exit-status --raw-output '.id' <<<"${repository}")"
  relative_path="$(jq --exit-status --raw-output '.relative_path' <<<"${repository}")"

  sync_task="$(foreman_api POST "/katello/api/repositories/${repository_id}/sync" '{}')"
  wait_for_task "$(task_id_from <<<"${sync_task}")"

  files="$(foreman_api GET "/katello/api/repositories/${repository_id}/files?per_page=all")"
  assert_equal "$(jq --raw-output '.total' <<<"${files}")" "1" "synced file count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].name' <<<"${files}")" \
    "${content_filename}" "synced file name"
  assert_equal "$(jq --exit-status --raw-output '.results[0].checksum' <<<"${files}")" \
    "${content_checksum}" "synced file checksum"
  assert_public_content "${relative_path}"

  content_view="$(foreman_api POST /katello/api/content_views "$(
    jq --compact-output --null-input \
      --argjson organization_id "${organization_id}" \
      --argjson repository_id "${repository_id}" '{
        organization_id: $organization_id,
        content_view: {
          name: "Kubernetes Integration View",
          label: "Kubernetes_Integration_View",
          repository_ids: [$repository_id]
        }
      }'
  )")"
  content_view_id="$(jq --exit-status --raw-output '.id' <<<"${content_view}")"

  publish_task="$(foreman_api POST "/katello/api/content_views/${content_view_id}/publish" \
    '{"description":"Foreman Kubernetes integration publication"}')"
  wait_for_task "$(task_id_from <<<"${publish_task}")"

  content_view="$(foreman_api GET "/katello/api/content_views/${content_view_id}")"
  content_view_version_id="$(jq --exit-status --raw-output '.latest_version_id' <<<"${content_view}")"
  content_view_version="$(foreman_api GET "/katello/api/content_view_versions/${content_view_version_id}")"
  published_repository_id="$(jq --exit-status --raw-output \
    --argjson repository_id "${repository_id}" \
    '.repositories[] | select(.library_instance_id == $repository_id) | .id' \
    <<<"${content_view_version}")"
  published_repository="$(foreman_api GET "/katello/api/repositories/${published_repository_id}")"
  published_relative_path="$(jq --exit-status --raw-output '.relative_path' <<<"${published_repository}")"
  assert_public_content "${published_relative_path}"

  library_environment="$(foreman_api GET \
    "/katello/api/organizations/${organization_id}/environments?library=true")"
  library_environment_id="$(jq --exit-status --raw-output '.results[0].id' <<<"${library_environment}")"
  content_view_environment="$(foreman_api GET \
    "/katello/api/content_view_environments?organization_id=${organization_id}&lifecycle_environment_id=${library_environment_id}&content_view_id=${content_view_id}")"
  assert_equal "$(jq --raw-output '.total' <<<"${content_view_environment}")" "1" \
    "published content view environment count"
  content_view_environment_id="$(jq --exit-status --raw-output '.results[0].id' \
    <<<"${content_view_environment}")"

  activation_key="$(foreman_api POST /katello/api/activation_keys "$(
    jq --compact-output --null-input \
      --argjson organization_id "${organization_id}" \
      --argjson content_view_environment_id "${content_view_environment_id}" '{
        organization_id: $organization_id,
        content_view_environment_ids: [$content_view_environment_id],
        activation_key: {
          name: "kubernetes-integration",
          unlimited_hosts: true,
          content_view_environment_ids: [$content_view_environment_id]
        }
      }'
  )")"
  activation_key_id="$(jq --exit-status --raw-output '.id' <<<"${activation_key}")"
  assert_equal "$(jq --exit-status --raw-output \
    '.content_view_environments[0].content_view.content_view_environment_id' <<<"${activation_key}")" \
    "${content_view_environment_id}" "activation key content view environment"

  jq --null-input \
    --argjson organization_id "${organization_id}" \
    --argjson product_id "${product_id}" \
    --argjson repository_id "${repository_id}" \
    --arg relative_path "${relative_path}" \
    --argjson content_view_id "${content_view_id}" \
    --argjson content_view_version_id "${content_view_version_id}" \
    --argjson published_repository_id "${published_repository_id}" \
    --arg published_relative_path "${published_relative_path}" \
    --argjson content_view_environment_id "${content_view_environment_id}" \
    --argjson activation_key_id "${activation_key_id}" '{
      organization_id: $organization_id,
      product_id: $product_id,
      repository_id: $repository_id,
      relative_path: $relative_path,
      content_view_id: $content_view_id,
      content_view_version_id: $content_view_version_id,
      published_repository_id: $published_repository_id,
      published_relative_path: $published_relative_path,
      content_view_environment_id: $content_view_environment_id,
      activation_key_id: $activation_key_id
    }' >"${state_file}"
}

assert_content_lifecycle() {
  local activation_key
  local activation_key_id
  local content_view
  local content_view_environment_id
  local content_view_id
  local content_view_version
  local content_view_version_id
  local files
  local organization_id
  local product_id
  local published_repository_id
  local published_relative_path
  local relative_path
  local repository
  local repository_id

  jq --exit-status '
    .organization_id and .product_id and .repository_id and .relative_path and
    .content_view_id and .content_view_version_id and .published_repository_id and
    .published_relative_path and .content_view_environment_id and .activation_key_id
  ' "${state_file}" >/dev/null

  organization_id="$(jq --raw-output '.organization_id' "${state_file}")"
  product_id="$(jq --raw-output '.product_id' "${state_file}")"
  repository_id="$(jq --raw-output '.repository_id' "${state_file}")"
  relative_path="$(jq --raw-output '.relative_path' "${state_file}")"
  content_view_id="$(jq --raw-output '.content_view_id' "${state_file}")"
  content_view_version_id="$(jq --raw-output '.content_view_version_id' "${state_file}")"
  published_repository_id="$(jq --raw-output '.published_repository_id' "${state_file}")"
  published_relative_path="$(jq --raw-output '.published_relative_path' "${state_file}")"
  content_view_environment_id="$(jq --raw-output '.content_view_environment_id' "${state_file}")"
  activation_key_id="$(jq --raw-output '.activation_key_id' "${state_file}")"

  assert_equal "$(foreman_api GET "/katello/api/organizations/${organization_id}" | jq --raw-output '.id')" \
    "${organization_id}" "restored organization"
  assert_equal "$(foreman_api GET "/katello/api/products/${product_id}" | jq --raw-output '.id')" \
    "${product_id}" "restored product"

  repository="$(foreman_api GET "/katello/api/repositories/${repository_id}")"
  assert_equal "$(jq --raw-output '.id' <<<"${repository}")" "${repository_id}" "restored repository"
  assert_equal "$(jq --raw-output '.relative_path' <<<"${repository}")" \
    "${relative_path}" "restored repository path"

  files="$(foreman_api GET "/katello/api/repositories/${repository_id}/files?per_page=all")"
  assert_equal "$(jq --raw-output '.total' <<<"${files}")" "1" "restored file count"
  assert_equal "$(jq --exit-status --raw-output '.results[0].checksum' <<<"${files}")" \
    "${content_checksum}" "restored file checksum"
  assert_public_content "${relative_path}"

  content_view="$(foreman_api GET "/katello/api/content_views/${content_view_id}")"
  assert_equal "$(jq --raw-output '.latest_version' <<<"${content_view}")" "1.0" \
    "restored content view version"
  assert_equal "$(jq --argjson repository_id "${repository_id}" \
    '[.repository_ids[] | select(. == $repository_id)] | length' <<<"${content_view}")" \
    "1" "restored content view repository count"

  content_view_version="$(foreman_api GET "/katello/api/content_view_versions/${content_view_version_id}")"
  assert_equal "$(jq --argjson published_repository_id "${published_repository_id}" \
    '[.repositories[].id | select(. == $published_repository_id)] | length' \
    <<<"${content_view_version}")" "1" "restored published repository count"
  assert_equal "$(foreman_api GET "/katello/api/repositories/${published_repository_id}" | \
    jq --raw-output '.relative_path')" "${published_relative_path}" "restored published repository path"
  assert_public_content "${published_relative_path}"

  activation_key="$(foreman_api GET "/katello/api/activation_keys/${activation_key_id}")"
  assert_equal "$(jq --exit-status --raw-output \
    '.content_view_environments[0].content_view.content_view_environment_id' <<<"${activation_key}")" \
    "${content_view_environment_id}" "restored activation key content view environment"
}

case "${mode}" in
  seed)
    seed_content_lifecycle
    assert_content_lifecycle
    ;;
  assert)
    assert_content_lifecycle
    ;;
  *)
    echo "mode must be seed or assert" >&2
    exit 2
    ;;
esac
