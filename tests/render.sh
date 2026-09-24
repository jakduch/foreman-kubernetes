#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="${repo_root}/charts/foreman-stack"
rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT

helm lint "${chart}"
helm template test "${chart}" > "${rendered}"
helm lint "${chart}" --values "${repo_root}/examples/cluster-values.yaml"
helm template test "${chart}" --values "${repo_root}/examples/cluster-values.yaml" >/dev/null

grep -q 'name: test-foreman-stack-foreman' "${rendered}"
grep -q 'name: test-foreman-stack-candlepin' "${rendered}"
grep -q 'name: test-foreman-stack-dynflow-orchestrator' "${rendered}"
grep -q 'name: test-foreman-stack-pulp-worker' "${rendered}"
grep -q 'replicas: 1' "${rendered}"

if helm template test "${chart}" --set candlepin.replicas=2 >/dev/null 2>&1; then
  echo 'expected candlepin.replicas=2 to be rejected by the schema' >&2
  exit 1
fi

echo 'Helm render checks passed.'
