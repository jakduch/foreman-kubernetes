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

cat > "${fake_bin}/helm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "${FAKE_TOOL_LOG}"
if [[ -n "${FAKE_HELM_FAIL_MATCH:-}" && "$*" == *"${FAKE_HELM_FAIL_MATCH}"* ]]; then
  match_count=1
  if [[ -n "${FAKE_HELM_MATCH_COUNT_FILE:-}" ]]; then
    if [[ -s "${FAKE_HELM_MATCH_COUNT_FILE}" ]]; then
      match_count="$(<"${FAKE_HELM_MATCH_COUNT_FILE}")"
      match_count=$((match_count + 1))
    fi
    printf '%s\n' "${match_count}" > "${FAKE_HELM_MATCH_COUNT_FILE}"
  fi
  if [[ "${match_count}" == "${FAKE_HELM_FAIL_ON_MATCH:-1}" ]]; then
    exit 1
  fi
fi
case "$*" in
  *'--show-only templates/foreman.yaml'*)
    printf '%s\n' 'kind: Service'
    if [[ "${FAKE_FOREMAN_DEPLOYMENT:-1}" == 1 ]]; then
      printf '%s\n' '---' 'kind: Deployment'
    fi
    ;;
  *'--show-only templates/dynflow.yaml'*)
    printf '%s\n' 'kind: Deployment' '---' 'kind: Deployment' '---' 'kind: Deployment'
    ;;
  *'--show-only templates/migrations.yaml'*)
    printf '%s\n' 'kind: Job' '---' 'kind: Job' '---' 'kind: Job'
    ;;
esac
SCRIPT

cat > "${fake_bin}/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${FAKE_TOOL_LOG}"
SCRIPT

chmod +x "${fake_bin}/helm" "${fake_bin}/kubectl"

if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'candidate compatibility set was accepted without explicit qualification opt-in' >&2
  exit 1
fi
if [[ -s "${tool_log}" ]]; then
  echo 'candidate gate invoked cluster tools before rejecting the release set' >&2
  exit 1
fi

PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null

cat > "${temporary_directory}/expected.log" <<EOF
helm status foreman --namespace foreman
helm status execution --namespace foreman
kubectl --namespace foreman wait --for=condition=Ready pod --selector=app.kubernetes.io/instance=execution,app.kubernetes.io/component=execution-proxy --timeout=10m
helm test foreman --namespace foreman --logs --timeout 10m
helm lint ${repo_root}/charts/foreman-stack --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml
helm template foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml
helm template foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --show-only templates/foreman.yaml
helm template foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --show-only templates/dynflow.yaml
helm template foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --show-only templates/migrations.yaml
helm lint ${repo_root}/charts/foreman-execution-proxy --values ${execution_values} --values ${repo_root}/profiles/execution-proxy-nightly-candidate-2026-09-24.yaml
helm template execution ${repo_root}/charts/foreman-execution-proxy --namespace foreman --values ${execution_values} --values ${repo_root}/profiles/execution-proxy-nightly-candidate-2026-09-24.yaml
helm upgrade foreman ${repo_root}/charts/foreman-stack --namespace foreman --values ${application_values} --values ${repo_root}/profiles/nightly-candidate-2026-09-23.yaml --wait --wait-for-jobs --timeout 30m
helm test foreman --namespace foreman --logs --timeout 10m
helm upgrade execution ${repo_root}/charts/foreman-execution-proxy --namespace foreman --values ${execution_values} --values ${repo_root}/profiles/execution-proxy-nightly-candidate-2026-09-24.yaml --wait --timeout 30m
kubectl --namespace foreman wait --for=condition=Ready pod --selector=app.kubernetes.io/instance=execution,app.kubernetes.io/component=execution-proxy --timeout=10m
helm test foreman --namespace foreman --logs --timeout 10m
EOF
diff -u "${temporary_directory}/expected.log" "${tool_log}"

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_HELM_FAIL_MATCH='upgrade foreman ' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'failed application upgrade unexpectedly succeeded' >&2
  exit 1
fi
if grep -Fq 'helm upgrade execution ' "${tool_log}"; then
  echo 'execution proxy was upgraded after the application upgrade failed' >&2
  exit 1
fi

: > "${tool_log}"
: > "${temporary_directory}/match-count"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_HELM_FAIL_MATCH='test foreman ' \
  FAKE_HELM_FAIL_ON_MATCH=2 \
  FAKE_HELM_MATCH_COUNT_FILE="${temporary_directory}/match-count" \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'failed post-upgrade application smoke test unexpectedly succeeded' >&2
  exit 1
fi
if grep -Fq 'helm upgrade execution ' "${tool_log}"; then
  echo 'execution proxy was upgraded after the application smoke test failed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_FOREMAN_DEPLOYMENT=0 \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/upgrade-release.sh" \
    "${application_values}" "${execution_values}" >/dev/null 2>&1; then
  echo 'maintenance-mode render was accepted by the normal upgrade helper' >&2
  exit 1
fi
if grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'an upgrade started after preflight detected maintenance mode' >&2
  exit 1
fi

if grep -Fq -- '--atomic' "${repo_root}/scripts/upgrade-release.sh"; then
  echo 'upgrade helper must not automatically roll back migrated schemas' >&2
  exit 1
fi

echo 'Upgrade release sequencing checks passed.'
