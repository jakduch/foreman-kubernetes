#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
fake_bin="${temporary_directory}/bin"
tool_log="${temporary_directory}/tools.log"
application_values="${temporary_directory}/application.yaml"
execution_values="${temporary_directory}/execution.yaml"

cleanup() {
  rm -rf "${temporary_directory}"
}
trap cleanup EXIT

mkdir -p "${fake_bin}"
: > "${application_values}"
: > "${execution_values}"
: > "${tool_log}"

cat > "${fake_bin}/helm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "${FAKE_TOOL_LOG}"
if [[ "$1" == list ]]; then
  [[ "${FAKE_HELM_LIST_FAIL:-0}" == 0 ]] || exit 1
  printf '%s\n' "${FAKE_HELM_LIST_JSON:-[]}"
  exit 0
fi
if [[ "$1" == template && "$2" == foreman ]]; then
  printf '%s\n' \
    'apiVersion: apps/v1' \
    'kind: Deployment' \
    'metadata:' \
    '  labels:' \
    '    app.kubernetes.io/component: foreman'
  if [[ "${FAKE_RENDER_SECRET:-0}" == 1 ]]; then
    printf '%s\n' \
      'spec:' \
      '  template:' \
      '    spec:' \
      '      containers:' \
      '        - name: foreman' \
      '          env:' \
      '            - name: PASSWORD' \
      '              valueFrom:' \
      '                secretKeyRef:' \
      '                  name: required-runtime' \
      '                  key: password'
  fi
  printf '%s\n' \
    '---' 'kind: Job' \
    '---' 'kind: Job' \
    '---' 'kind: Job' \
    '---' 'kind: Job'
  if [[ "${FAKE_RENDER_INGRESS:-0}" == 1 ]]; then
    printf '%s\n' \
      '---' \
      'apiVersion: networking.k8s.io/v1' \
      'kind: Ingress' \
      'metadata:' \
      '  annotations:' \
      '    foreman-kubernetes.io/required-ingress-controller: k8s.io/ingress-nginx' \
      'spec:' \
      '  ingressClassName: nginx'
  fi
fi
if [[ -n "${FAKE_HELM_FAIL_MATCH:-}" && "$*" == *"${FAKE_HELM_FAIL_MATCH}"* ]]; then
  exit 1
fi
SCRIPT

cat > "${fake_bin}/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${FAKE_TOOL_LOG}"
if [[ "$*" == *'get secret required-runtime'* ]]; then
  if [[ -z "${FAKE_SECRET_JSON:-}" ]]; then
    exit 1
  fi
  printf '%s\n' "${FAKE_SECRET_JSON}"
fi
if [[ "$*" == 'get storageclass --output=json' ]]; then
  printf '%s\n' '{"items":[{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}]}'
fi
if [[ "$*" == 'get IngressClass nginx --output=json' ]]; then
  printf '{"spec":{"controller":"%s"}}\n' "${FAKE_INGRESS_CONTROLLER:-k8s.io/ingress-nginx}"
fi
SCRIPT

chmod +x "${fake_bin}/helm" "${fake_bin}/kubectl"

if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'candidate compatibility set was accepted without explicit qualification opt-in' >&2
  exit 1
fi
if [[ -s "${tool_log}" ]]; then
  echo 'candidate gate invoked cluster tools before rejecting the release set' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_HELM_LIST_FAIL=1 \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation treated a Helm release-list failure as an empty namespace' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after Helm release discovery failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_HELM_LIST_JSON='[{"name":"foreman"}]' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted an existing application release' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation overwrote an existing release' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null

application_install="helm upgrade --install foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --wait --wait-for-jobs --timeout 30m"
execution_install="helm upgrade --install execution ${repo_root}/charts/foreman-execution-proxy --namespace foreman --values ${execution_values} --values ${repo_root}/profiles/execution-proxy-nightly-candidate-2026-09-24.yaml --wait --timeout 30m"

grep -Fqx "${application_install}" "${tool_log}"
grep -Fqx "${execution_install}" "${tool_log}"

application_line="$(grep -Fn "${application_install}" "${tool_log}" | cut -d: -f1)"
first_smoke_line="$(grep -Fn 'helm test foreman --namespace foreman --logs --timeout 10m' "${tool_log}" | head -n 1 | cut -d: -f1)"
execution_line="$(grep -Fn "${execution_install}" "${tool_log}" | cut -d: -f1)"
if ! (( application_line < first_smoke_line && first_smoke_line < execution_line )); then
  echo 'execution proxy was installed before the application smoke gate' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_HELM_FAIL_MATCH='test foreman ' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'failed application smoke test unexpectedly succeeded' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install execution ' "${tool_log}"; then
  echo 'execution proxy was installed after the application smoke test failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_SECRET=1 \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted a missing externally managed Secret' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after Secret preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_SECRET=1 \
  FAKE_SECRET_JSON='{"data":{"username":"dXNlcg=="}}' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted an externally managed Secret without its required key' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after Secret key preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RENDER_INGRESS=1 \
  FAKE_INGRESS_CONTROLLER=example.invalid/controller \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/install-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'installation accepted an incompatible ingress implementation' >&2
  exit 1
fi
if grep -Fq 'helm upgrade --install ' "${tool_log}"; then
  echo 'installation started after ingress implementation preflight failed' >&2
  exit 1
fi

if grep -Fq -- '--atomic' "${repo_root}/scripts/install-release.sh"; then
  echo 'install helper must not automatically roll back migrated schemas' >&2
  exit 1
fi

echo 'Install release sequencing checks passed.'
