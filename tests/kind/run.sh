#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cluster_name="${KIND_CLUSTER_NAME:-foreman-stack-e2e}"
namespace="foreman"
release="foreman"
image_profile="${IMAGE_PROFILE:-${repo_root}/profiles/nightly-candidate-2026-09-23.yaml}"
kind_node_image="${KIND_NODE_IMAGE:-kindest/node:v1.34.11@sha256:44e222ee2132dab25ff87301682f89eb82c7880ea3a1bf543bfe9708fd08d67d}"
created_cluster=false
temporary_directory="$(mktemp -d)"
skip_recovery_test="${SKIP_RECOVERY_TEST:-0}"

helm_apply() {
  helm upgrade --install "${release}" "${repo_root}/charts/foreman-stack" \
    --namespace "${namespace}" \
    --values "${repo_root}/tests/kind/values.yaml" \
    --values "${image_profile}" \
    --wait \
    --wait-for-jobs \
    --timeout 30m \
    "$@"
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
  kubectl create namespace "${namespace}" --dry-run=client --output=yaml | kubectl apply --filename=-
  kubectl apply --filename="${repo_root}/tests/kind/dependencies.yaml"
  kubectl --namespace "${namespace}" rollout status deployment/postgresql --timeout=5m
  kubectl --namespace "${namespace}" rollout status deployment/valkey --timeout=5m
  "${repo_root}/tests/kind/apply-secrets.sh" "${temporary_directory}"
}

reset_namespace_for_restore() {
  local kind_node="${cluster_name}-control-plane"

  kubectl delete namespace "${namespace}" --wait=true
  kubectl delete persistentvolume \
    foreman-kind-pulp-data \
    foreman-kind-recovery-repository \
    --ignore-not-found=true \
    --wait=true

  docker exec "${kind_node}" \
    find /var/local/foreman-kind-pulp \
    -mindepth 1 \
    -maxdepth 1 \
    -exec rm -rf -- '{}' +
  docker exec "${kind_node}" test -f /var/local/foreman-kind-recovery/config

  install_dependencies
  set_secret_probe after-reset
  assert_secret_probe after-reset
  assert_database_probes_absent
  docker exec "${kind_node}" test ! -e /var/local/foreman-kind-pulp/recovery-probe
}

cleanup() {
  local exit_status=$?
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

for command_name in kind kubectl helm openssl curl; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "${command_name} is required" >&2
    exit 1
  fi
done

if [[ ! -f "${image_profile}" ]]; then
  echo "image profile does not exist: ${image_profile}" >&2
  exit 1
fi

if [[ "${skip_recovery_test}" != 1 ]] && ! command -v docker >/dev/null 2>&1; then
  echo "docker is required unless SKIP_RECOVERY_TEST=1" >&2
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

helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  --wait \
  --timeout 10m

install_dependencies

helm_apply

kubectl --namespace "${namespace}" wait \
  --for=condition=complete \
  job \
  --selector=app.kubernetes.io/component=pulp-registration \
  --timeout=10m

assert_foreman_ready

pulp_api_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --cacert "${temporary_directory}/ca.crt" \
  --resolve content.test:8443:127.0.0.1 \
  https://content.test:8443/pulp/api/v3/status/)"
if [[ "${pulp_api_status}" != 404 ]]; then
  echo "public Pulp API returned ${pulp_api_status}, expected 404" >&2
  exit 1
fi

assert_pulp_registration

if [[ "${skip_recovery_test}" != 1 ]]; then
  set_database_probes before-backup
  set_pulp_probe before-backup
  assert_secret_probe before-backup

  helm_apply \
    --set maintenance.enabled=true \
    --set backup.enabled=true \
    --set backup.requestId=e2e-backup \
    --set backup.initializeRepository=true

  helm_apply

  set_database_probes after-backup
  set_pulp_probe after-backup
  set_secret_probe after-backup
  assert_database_probes after-backup
  assert_pulp_probe after-backup
  assert_secret_probe after-backup

  reset_namespace_for_restore

  helm_apply \
    --set maintenance.enabled=true \
    --set restore.enabled=true \
    --set restore.requestId=e2e-restore \
    --set restore.snapshot=latest \
    --set restore.secrets=true \
    --set restore.confirmation=RESTORE

  helm_apply

  assert_foreman_ready
  assert_pulp_registration
  assert_database_probes before-backup
  assert_pulp_probe before-backup
  assert_secret_probe before-backup
fi

kubectl --namespace "${namespace}" scale \
  deployment/foreman-foreman-stack-dynflow-worker \
  --replicas=2
kubectl --namespace "${namespace}" rollout status \
  deployment/foreman-foreman-stack-dynflow-worker \
  --timeout=10m

helm_apply \
  --set foreman.puma.threadsMax=6 \
  --set foreman.dynflow.workers=2

kubectl --namespace "${namespace}" rollout status \
  deployment/foreman-foreman-stack-foreman \
  --timeout=10m

if [[ "${skip_recovery_test}" == 1 ]]; then
  echo "Kind install, mTLS, registration, scale, and upgrade checks passed; recovery drill skipped."
else
  echo "Kind install, mTLS, registration, backup, restore, scale, and upgrade checks passed."
fi
