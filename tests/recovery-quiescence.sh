#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
fake_bin="${temporary_directory}/bin"

cleanup() {
  rm -rf "${temporary_directory}"
}
trap cleanup EXIT

mkdir -p "${fake_bin}"
cat > "${fake_bin}/kubectl" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${FAKE_PODS_JSON}"
SCRIPT
chmod +x "${fake_bin}/kubectl"

terminal_pods='{
  "items": [
    {
      "metadata": {
        "name": "completed-migration",
        "labels": {
          "app.kubernetes.io/instance": "foreman",
          "app.kubernetes.io/component": "foreman-migrate"
        }
      },
      "status": {"phase": "Succeeded"}
    },
    {
      "metadata": {
        "name": "unrelated-running-pod",
        "labels": {
          "app.kubernetes.io/instance": "foreman",
          "app.kubernetes.io/component": "unrelated"
        }
      },
      "status": {"phase": "Running"}
    }
  ]
}'

PATH="${fake_bin}:${PATH}" \
FAKE_PODS_JSON="${terminal_pods}" \
POD_NAMESPACE=foreman \
HELM_RELEASE=foreman \
QUIESCENCE_TIMEOUT_SECONDS=0 \
  bash -c '. "$1"; wait_for_quiescence' _ \
    "${repo_root}/charts/foreman-stack/files/recovery-common.sh" >/dev/null

terminating_writer='{
  "items": [
    {
      "metadata": {
        "name": "terminating-worker",
        "deletionTimestamp": "2026-09-24T12:00:00Z",
        "labels": {
          "app.kubernetes.io/instance": "foreman",
          "app.kubernetes.io/component": "dynflow-worker"
        }
      },
      "status": {"phase": "Running"}
    }
  ]
}'

if PATH="${fake_bin}:${PATH}" \
  FAKE_PODS_JSON="${terminating_writer}" \
  POD_NAMESPACE=foreman \
  HELM_RELEASE=foreman \
  QUIESCENCE_TIMEOUT_SECONDS=0 \
    bash -c '. "$1"; wait_for_quiescence' _ \
      "${repo_root}/charts/foreman-stack/files/recovery-common.sh" \
      >"${temporary_directory}/terminating.log" 2>&1; then
  echo 'terminating database writer was treated as quiescent' >&2
  exit 1
fi
grep -q 'terminating-worker' "${temporary_directory}/terminating.log"

echo 'Recovery quiescence checks passed.'
