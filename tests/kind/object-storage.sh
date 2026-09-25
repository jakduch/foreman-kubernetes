#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
namespace="${NAMESPACE:-foreman}"
compatibility_set="${COMPATIBILITY_SET:?COMPATIBILITY_SET is required}"
image_profile="${IMAGE_PROFILE:?IMAGE_PROFILE is required}"
output_file="${PULP_OBJECT_STORAGE_EVIDENCE_FILE:-artifacts/pulp-object-storage.json}"
job_name=foreman-foreman-stack-pulp-object-storage-test
secret_name=pulp-object-storage-probe
last_probe_logs=""
last_probe_result=""

apply_probe_credentials() {
  local access_key="$1"
  local secret_key="$2"

  kubectl --namespace "${namespace}" create secret generic "${secret_name}" \
    --from-literal=access-key-id="${access_key}" \
    --from-literal=secret-access-key="${secret_key}" \
    --dry-run=client --output=yaml | \
    kubectl --namespace "${namespace}" apply --filename=- >/dev/null
}

start_probe() {
  kubectl --namespace "${namespace}" delete job "${job_name}" \
    --ignore-not-found --wait=true >/dev/null
  kubectl --namespace "${namespace}" apply --filename="${manifest}" >/dev/null
}

run_successful_probe() {
  start_probe
  if ! kubectl --namespace "${namespace}" wait \
    --for=condition=complete "job/${job_name}" --timeout=10m >/dev/null; then
    kubectl --namespace "${namespace}" logs "job/${job_name}" >&2 || true
    kubectl --namespace "${namespace}" describe "job/${job_name}" >&2 || true
    return 1
  fi

  last_probe_logs="$(kubectl --namespace "${namespace}" logs "job/${job_name}")"
  last_probe_result="$(jq --raw-input --slurp '
    [split("\n")[] | fromjson? | select(type == "object" and has("backend"))] | last
  ' <<<"${last_probe_logs}")"
  jq --exit-status '
    .backend == "S3Storage" and
    .bucket == "foreman-pulp-probe" and
    .location == "qualification" and
    .bytes == 9437185 and
    .directDownload == true and
    .objectVersions >= 1 and
    .deleteMarkers >= 1
  ' <<<"${last_probe_result}" >/dev/null
}

require_old_credentials_rejected() {
  start_probe
  if kubectl --namespace "${namespace}" wait \
    --for=condition=complete "job/${job_name}" --timeout=45s >/dev/null 2>&1; then
    echo 'The retired object-storage credentials still completed a write' >&2
    return 1
  fi
  kubectl --namespace "${namespace}" wait \
    --for=condition=failed "job/${job_name}" --timeout=3m >/dev/null
  old_credential_logs="$(kubectl --namespace "${namespace}" logs "job/${job_name}")"
  if ! grep -Eiq 'InvalidAccessKeyId|SignatureDoesNotMatch|AccessDenied' \
    <<<"${old_credential_logs}"; then
    echo 'The old-credential probe failed without an S3 authentication error' >&2
    printf '%s\n' "${old_credential_logs}" >&2
    return 1
  fi
}

kubectl apply --filename="${repo_root}/tests/kind/object-storage.yaml" >/dev/null
kubectl --namespace "${namespace}" rollout status \
  deployment/object-storage --timeout=10m >/dev/null

apply_probe_credentials foreman-pulp-test foreman-pulp-secret-test

manifest="$(mktemp)"
trap 'rm -f "${manifest}"' EXIT
helm template foreman "${repo_root}/charts/foreman-stack" \
  --namespace "${namespace}" \
  --values "${repo_root}/tests/kind/values.yaml" \
  --values "${repo_root}/examples/execution-control-plane-values.yaml" \
  --values "${image_profile}" \
  --set pulp.storage.backend=s3 \
  --set-string pulp.storage.existingClaim= \
  --set-string pulp.storage.s3.bucket=foreman-pulp-probe \
  --set-string pulp.storage.s3.location=qualification \
  --set-string pulp.storage.s3.region=us-east-1 \
  --set-string pulp.storage.s3.endpointUrl=http://object-storage:8333 \
  --set-string pulp.storage.s3.addressingStyle=path \
  --set pulp.storage.s3.redirectToObjectStorage=true \
  --set-string pulp.storage.s3.existingSecret="${secret_name}" \
  --show-only templates/tests/pulp-object-storage.yaml \
  >"${manifest}"

run_successful_probe
initial_result="${last_probe_result}"
printf '%s\n' "${last_probe_logs}"

kubectl --namespace "${namespace}" set env deployment/object-storage \
  AWS_ACCESS_KEY_ID=foreman-pulp-rotated \
  AWS_SECRET_ACCESS_KEY=foreman-pulp-secret-rotated >/dev/null
kubectl --namespace "${namespace}" rollout status \
  deployment/object-storage --timeout=10m >/dev/null
require_old_credentials_rejected

apply_probe_credentials foreman-pulp-rotated foreman-pulp-secret-rotated
run_successful_probe
rotated_result="${last_probe_result}"
printf '%s\n' "${last_probe_logs}"

mkdir -p "$(dirname "${output_file}")"
jq --null-input \
  --arg compatibility_set "${compatibility_set}" \
  --arg emulator_image "chrislusf/seaweedfs:4.47@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882" \
  --argjson initial "${initial_result}" \
  --argjson rotated "${rotated_result}" \
  '{
    compatibilitySet: $compatibility_set,
    emulatorImage: $emulator_image,
    oldCredentialsRejected: true,
    initial: $initial,
    rotated: $rotated
  }' >"${output_file}"

echo 'Pulp completed direct versioned multipart transfers before and after credential rotation.'
