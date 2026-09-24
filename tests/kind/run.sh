#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cluster_name="${KIND_CLUSTER_NAME:-foreman-stack-e2e}"
namespace="foreman"
release="foreman"
image_profile="${IMAGE_PROFILE:-${repo_root}/profiles/nightly-candidate-2026-09-23.yaml}"
created_cluster=false
temporary_directory="$(mktemp -d)"

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
    --config "${repo_root}/tests/kind/kind-config.yaml"
  created_cluster=true
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

kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${repo_root}/tests/kind/dependencies.yaml"
kubectl --namespace "${namespace}" rollout status deployment/postgresql --timeout=5m
kubectl --namespace "${namespace}" rollout status deployment/valkey --timeout=5m
"${repo_root}/tests/kind/apply-secrets.sh" "${temporary_directory}"

helm upgrade --install "${release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${repo_root}/tests/kind/values.yaml" \
  --values "${image_profile}" \
  --wait \
  --wait-for-jobs \
  --timeout 30m

kubectl --namespace "${namespace}" wait \
  --for=condition=complete \
  job \
  --selector=app.kubernetes.io/component=pulp-registration \
  --timeout=10m

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

pulp_api_status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --cacert "${temporary_directory}/ca.crt" \
  --resolve content.test:8443:127.0.0.1 \
  https://content.test:8443/pulp/api/v3/status/)"
if [[ "${pulp_api_status}" != 404 ]]; then
  echo "public Pulp API returned ${pulp_api_status}, expected 404" >&2
  exit 1
fi

foreman_pod="$(kubectl --namespace "${namespace}" get pod \
  --selector=app.kubernetes.io/component=foreman \
  --output=jsonpath='{.items[0].metadata.name}')"
kubectl --namespace "${namespace}" exec "${foreman_pod}" -- \
  bin/rails runner 'abort "Pulp proxy missing" unless SmartProxy.pulp_primary&.has_feature?("Pulpcore")'

kubectl --namespace "${namespace}" scale \
  deployment/foreman-foreman-stack-dynflow-worker \
  --replicas=2
kubectl --namespace "${namespace}" rollout status \
  deployment/foreman-foreman-stack-dynflow-worker \
  --timeout=10m

helm upgrade "${release}" "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${repo_root}/tests/kind/values.yaml" \
  --values "${image_profile}" \
  --set foreman.puma.threadsMax=6 \
  --wait \
  --wait-for-jobs \
  --timeout 30m

kubectl --namespace "${namespace}" rollout status \
  deployment/foreman-foreman-stack-foreman \
  --timeout=10m

echo "Kind install, mTLS, registration, scale, and upgrade checks passed."
