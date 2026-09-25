#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
namespace="${NAMESPACE:-foreman}"
compatibility_set="${COMPATIBILITY_SET:?COMPATIBILITY_SET is required}"
image_profile="${IMAGE_PROFILE:?IMAGE_PROFILE is required}"
output_file="${PULP_OBJECT_STORAGE_EVIDENCE_FILE:-artifacts/pulp-object-storage.json}"
job_name=foreman-foreman-stack-pulp-object-storage-test
secret_name=pulp-object-storage-probe

kubectl apply --filename="${repo_root}/tests/kind/object-storage.yaml" >/dev/null
kubectl --namespace "${namespace}" rollout status \
  deployment/object-storage --timeout=10m >/dev/null

kubectl --namespace "${namespace}" create secret generic "${secret_name}" \
  --from-literal=access-key-id=foreman-pulp-test \
  --from-literal=secret-access-key=foreman-pulp-secret-test \
  --dry-run=client --output=yaml | \
  kubectl --namespace "${namespace}" apply --filename=- >/dev/null

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
  --set pulp.storage.s3.redirectToObjectStorage=false \
  --set-string pulp.storage.s3.existingSecret="${secret_name}" \
  --show-only templates/tests/pulp-object-storage.yaml \
  >"${manifest}"

kubectl --namespace "${namespace}" delete job "${job_name}" \
  --ignore-not-found --wait=true >/dev/null
kubectl --namespace "${namespace}" apply --filename="${manifest}" >/dev/null
if ! kubectl --namespace "${namespace}" wait \
  --for=condition=complete "job/${job_name}" --timeout=10m >/dev/null; then
  kubectl --namespace "${namespace}" logs "job/${job_name}" >&2 || true
  kubectl --namespace "${namespace}" describe "job/${job_name}" >&2 || true
  exit 1
fi

logs="$(kubectl --namespace "${namespace}" logs "job/${job_name}")"
result="$(jq --raw-input --slurp '
  [split("\n")[] | fromjson? | select(type == "object" and has("backend"))] | last
' <<<"${logs}")"
jq --exit-status '
  .backend == "S3Storage" and
  .bucket == "foreman-pulp-probe" and
  .location == "qualification" and
  .bytes == 9437185 and
  .objectVersions >= 1 and
  .deleteMarkers >= 1
' <<<"${result}" >/dev/null

mkdir -p "$(dirname "${output_file}")"
jq --null-input \
  --arg compatibility_set "${compatibility_set}" \
  --arg emulator_image "chrislusf/seaweedfs:4.47@sha256:ce9e796f1fe6f06968f4c04bdaf8f678dad9c8acdfef3d244133d71bfa6bf882" \
  --argjson result "${result}" \
  '{
    compatibilitySet: $compatibility_set,
    emulatorImage: $emulator_image,
    result: $result
  }' >"${output_file}"

printf '%s\n' "${logs}"
echo 'Pulp completed a versioned multipart object-storage round trip.'
