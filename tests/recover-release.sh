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
export RELEASE_HOLDER_ID=test-recovery-holder

cat > "${fake_bin}/helm" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >> "${FAKE_TOOL_LOG}"
if [[ "${FAKE_RECOVERY_UPGRADE_FAIL:-0}" == 1 && "$1" == upgrade && "$*" == *'backup.enabled=true'* ]]; then
  exit 1
fi
case "$*" in
  'get values foreman --namespace foreman --all --output=json')
    printf '{"platform":{"compatibilitySet":"%s"}}\n' "${FAKE_APPLICATION_SET:-nightly-candidate-2026-09-24}"
    ;;
  'get values execution --namespace foreman --all --output=json')
    printf '{"compatibilitySet":"%s"}\n' "${FAKE_EXECUTION_SET:-nightly-candidate-2026-09-24}"
    ;;
esac
if [[ "$1" == template && "$2" == foreman ]]; then
  if [[ "$*" == *'maintenance.enabled=true'* ]]; then
    printf '%s\n' 'apiVersion: batch/v1' 'kind: Job' 'metadata:' '  name: recovery'
  else
    printf '%s\n' 'apiVersion: apps/v1' 'kind: Deployment' 'metadata:' '  name: foreman'
  fi
fi
SCRIPT

cat > "${fake_bin}/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >> "${FAKE_TOOL_LOG}"
if [[ -n "${FAKE_KUBECTL_FAIL_MATCH:-}" && "$*" == *"${FAKE_KUBECTL_FAIL_MATCH}"* ]]; then
  exit 1
fi
if [[ "$*" == *'get lease foreman-kubernetes-release --output=jsonpath={.spec.holderIdentity}' ]]; then
  printf '%s' "${RELEASE_HOLDER_ID}"
fi
SCRIPT

chmod +x "${fake_bin}/helm" "${fake_bin}/kubectl"

if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-1 >/dev/null 2>&1; then
  echo 'candidate compatibility set was accepted without explicit qualification opt-in' >&2
  exit 1
fi
if [[ -s "${tool_log}" ]]; then
  echo 'candidate gate invoked cluster tools before rejecting recovery' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_EXECUTION_SET='previous-set' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-0 >/dev/null 2>&1; then
  echo 'recovery accepted application and execution proxy from different compatibility sets' >&2
  exit 1
fi
if grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'recovery mutation started after installed-set validation failed' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  INITIALIZE_REPOSITORY=1 \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-1 >/dev/null

recovery_upgrade='helm upgrade foreman'
normal_upgrade='--set maintenance.enabled=false --set backup.enabled=false --set restore.enabled=false'
grep -Fq -- '--set backup.enabled=true --set-string backup.requestId=request-1 --set backup.initializeRepository=true' "${tool_log}"
grep -Fq -- "${normal_upgrade}" "${tool_log}"
grep -Fq 'kubectl --namespace foreman apply --dry-run=server --filename -' "${tool_log}"
recovery_line="$(grep -Fn "${recovery_upgrade}" "${tool_log}" | grep 'maintenance.enabled=true' | cut -d: -f1)"
normal_line="$(grep -Fn "${recovery_upgrade}" "${tool_log}" | grep -- "${normal_upgrade}" | cut -d: -f1)"
if ! (( recovery_line < normal_line )); then
  echo 'normal workloads resumed before the recovery Job completed' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_RECOVERY_UPGRADE_FAIL=1 \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-2 >/dev/null 2>&1; then
  echo 'failed backup unexpectedly succeeded' >&2
  exit 1
fi
if grep -Fq -- "${normal_upgrade}" "${tool_log}"; then
  echo 'application left maintenance mode after a failed backup' >&2
  exit 1
fi

: > "${tool_log}"
if PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  FAKE_KUBECTL_FAIL_MATCH='apply --dry-run=server' \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/recover-release.sh" backup \
    "${application_values}" "${execution_values}" request-admission >/dev/null 2>&1; then
  echo 'recovery accepted a server-side admission rejection' >&2
  exit 1
fi
if grep -Fq 'helm upgrade ' "${tool_log}"; then
  echo 'recovery mutation started after admission preflight failed' >&2
  exit 1
fi

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  RESTORE_SNAPSHOT=abc123 \
  RESTORE_SECRETS=1 \
  OBJECT_STORAGE_CONFIRMATION=BUCKET_RESTORED \
  "${repo_root}/scripts/recover-release.sh" restore \
    "${application_values}" "${execution_values}" request-3 >/dev/null
grep -Fq -- '--set restore.enabled=true --set-string restore.requestId=request-3 --set-string restore.snapshot=abc123 --set restore.confirmation=RESTORE --set restore.secrets=true --set-string restore.objectStorageConfirmation=BUCKET_RESTORED' "${tool_log}"

: > "${tool_log}"
PATH="${fake_bin}:${PATH}" \
  FAKE_TOOL_LOG="${tool_log}" \
  ALLOW_CANDIDATE=1 \
  "${repo_root}/scripts/recover-release.sh" resume \
    "${application_values}" "${execution_values}" >/dev/null
grep -Fq -- "${normal_upgrade}" "${tool_log}"
if grep -Fq -- 'maintenance.enabled=true' "${tool_log}"; then
  echo 'resume unexpectedly rendered or ran another recovery Job' >&2
  exit 1
fi

if grep -Fq -- '--atomic' "${repo_root}/scripts/recover-release.sh"; then
  echo 'recovery helper must not automatically roll back restored schemas or data' >&2
  exit 1
fi

echo 'Guarded recovery sequencing checks passed.'
