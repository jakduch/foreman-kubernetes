#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="${repo_root}/charts/foreman-stack"
rendered="$(mktemp)"
rendered_ingress="$(mktemp)"
rendered_backup="$(mktemp)"
rendered_restore="$(mktemp)"
rendered_egress="$(mktemp)"
rendered_singletons="$(mktemp)"
trap 'rm -f "${rendered}" "${rendered_ingress}" "${rendered_backup}" "${rendered_restore}" "${rendered_egress}" "${rendered_singletons}"' EXIT

helm lint "${chart}"
helm template test "${chart}" > "${rendered}"
helm lint "${chart}" --values "${repo_root}/examples/cluster-values.yaml"
helm template test "${chart}" --values "${repo_root}/examples/cluster-values.yaml" > "${rendered_ingress}"
helm lint "${chart}" --values "${repo_root}/tests/kind/values.yaml"
helm lint "${chart}" --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml"
helm lint "${chart}" --values "${repo_root}/tests/egress-values.yaml"
helm template foreman "${chart}" \
  --values "${repo_root}/tests/kind/values.yaml" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" >/dev/null
helm template test "${chart}" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=20260924-120000 > "${rendered_backup}"
helm template test "${chart}" \
  --set maintenance.enabled=true \
  --set restore.enabled=true \
  --set restore.requestId=20260924-130000 \
  --set restore.confirmation=RESTORE > "${rendered_restore}"
helm template test "${chart}" \
  --values "${repo_root}/tests/egress-values.yaml" > "${rendered_egress}"
helm template test "${chart}" \
  --set foreman.replicas=1 \
  --set foreman.dynflow.workers=1 \
  --set foreman.dynflow.hostsQueueWorkers=1 \
  --set pulp.api.replicas=1 \
  --set pulp.content.replicas=1 \
  --set pulp.workers.replicas=1 > "${rendered_singletons}"

shellcheck -x \
  -P "${chart}/files" \
  "${chart}/files/recovery-common.sh" \
  "${chart}/files/backup.sh" \
  "${chart}/files/restore.sh"

grep -q 'name: test-foreman-stack-foreman' "${rendered}"
grep -q 'name: test-foreman-stack-candlepin' "${rendered}"
grep -q 'name: test-foreman-stack-dynflow-orchestrator' "${rendered}"
grep -q 'name: test-foreman-stack-pulp-worker' "${rendered}"
grep -q 'replicas: 1' "${rendered}"
grep -q 'name: test-foreman-stack-foreman-config' "${rendered}"
grep -q 'CANDLEPIN_AUTH_OAUTH_CONSUMER_KATELLO_SECRET' "${rendered}"
grep -q 'JPA_CONFIG_HIBERNATE_CONNECTION_PASSWORD' "${rendered}"
grep -q 'PULP_DATABASES__default__PASSWORD' "${rendered}"
grep -q "ENV.fetch('CANDLEPIN_OAUTH_SECRET')" "${rendered}"
grep -q 'name: wait-for-pulp-migrations' "${rendered}"
grep -q 'name: wait-for-foreman-migrations' "${rendered}"
grep -q 'name: test-foreman-stack-pulp-control' "${rendered}"
grep -q 'PULP_PROXY_URL' "${rendered}"
grep -q 'PULP_SMART_PROXY_RHSM_URL' "${rendered}"
grep -q 'https://foreman.example.test/rhsm' "${rendered}"
grep -q 'https://test-foreman-stack-pulp-control' "${rendered}"
if grep -q 'https://test-foreman-stack-pulp-control:8443' "${rendered}"; then
  echo 'Katello ignores non-standard ports in the advertised Pulp URL' >&2
  exit 1
fi
grep -q 'nginx.ingress.kubernetes.io/auth-tls-verify-client: optional' "${rendered_ingress}"
grep -Fq "X-CLIENT-CERT: \$ssl_client_escaped_cert" "${rendered_ingress}"
grep -q 'path: /pulp/content' "${rendered_ingress}"
grep -q 'path: /pulp_ansible/galaxy' "${rendered_ingress}"
if [[ "$(grep -c '^kind: HorizontalPodAutoscaler$' "${rendered_ingress}")" -ne 3 ]]; then
  echo 'expected Foreman, Pulp API, and Pulp content autoscalers' >&2
  exit 1
fi
grep -q 'name: test-foreman-stack-pulp-api' "${rendered}"
grep -q 'kind: NetworkPolicy' "${rendered}"
grep -q 'app.kubernetes.io/component: pulp-control-proxy' "${rendered}"
grep -q 'automountServiceAccountToken: false' "${rendered}"
grep -q 'runAsUser: 994' "${rendered}"
grep -q 'runAsUser: 700' "${rendered}"
grep -q 'type: RuntimeDefault' "${rendered}"
grep -q 'name: test-foreman-stack-dynflow-worker' "${rendered}"
if [[ "$(grep -c 'startupProbe:' "${rendered}")" -ne 5 ]]; then
  echo 'expected startup probes for Foreman, Candlepin, Pulp API/content, and the Pulp control proxy' >&2
  exit 1
fi
if [[ "$(grep -A3 'livenessProbe:' "${rendered}" | grep -c 'tcpSocket:')" -ne 5 ]]; then
  echo 'application liveness probes must test the local listener only' >&2
  exit 1
fi
if grep -A3 'livenessProbe:' "${rendered}" | grep -q 'httpGet:'; then
  echo 'application liveness probes must not restart pods for dependency health failures' >&2
  exit 1
fi
grep -A4 'readinessProbe:' "${rendered}" | grep -q '/api/v2/ping'
grep -A4 'readinessProbe:' "${rendered}" | grep -q '/candlepin/status'
grep -A4 'readinessProbe:' "${rendered}" | grep -q '/pulp/api/v3/status/'

if [[ "$(grep -c '^kind: PodDisruptionBudget$' "${rendered}")" -ne 6 ]]; then
  echo 'expected disruption budgets for the default redundant workloads' >&2
  exit 1
fi
if [[ "$(grep -c '^kind: PodDisruptionBudget$' "${rendered_singletons}")" -ne 1 ]]; then
  echo 'singleton workloads must not receive drain-blocking disruption budgets' >&2
  exit 1
fi
grep -A4 '^kind: PodDisruptionBudget$' "${rendered_singletons}" | \
  grep -q 'name: test-foreman-stack-pulp-control'

if [[ "$(grep -c '^    - Egress$' "${rendered_egress}")" -ne 4 ]]; then
  echo 'expected component-scoped Foreman, Pulp, Candlepin, and control-proxy egress policies' >&2
  exit 1
fi
grep -q 'cidr: 192.0.2.10/32' "${rendered_egress}"
grep -q 'cidr: 192.0.2.11/32' "${rendered_egress}"
grep -q 'cidr: 198.51.100.0/24' "${rendered_egress}"
grep -q 'cidr: 203.0.113.0/24' "${rendered_egress}"

grep -q 'app.kubernetes.io/component: recovery-backup' "${rendered_backup}"
grep -q 'name: BACKUP_REQUEST_ID' "${rendered_backup}"
grep -q 'name: RESTIC_CACHE_DIR' "${rendered_backup}"
grep -q 'resourceNames:' "${rendered_backup}"
grep -q 'name: test-foreman-stack-backup-20260924-120000' "${rendered_backup}"
if [[ "$(grep -c '^kind: Deployment$' "${rendered_backup}")" -ne 1 ]]; then
  echo 'maintenance backup must retain only the non-writing Pulp control proxy Deployment' >&2
  exit 1
fi
if [[ "$(grep -c '^kind: Job$' "${rendered_backup}")" -ne 1 ]]; then
  echo 'maintenance backup must render only the requested backup Job' >&2
  exit 1
fi

grep -q 'app.kubernetes.io/component: recovery-restore' "${rendered_restore}"
grep -q 'name: RESTORE_CONFIRMATION' "${rendered_restore}"
grep -A1 'name: RESTORE_CONFIRMATION' "${rendered_restore}" | grep -Eq 'value: "?RESTORE"?'
grep -q 'name: test-foreman-stack-restore-20260924-130000' "${rendered_restore}"
if [[ "$(grep -c '^kind: Job$' "${rendered_restore}")" -ne 1 ]]; then
  echo 'maintenance restore must render only the requested restore Job' >&2
  exit 1
fi

if grep -q 'helm.sh/hook: pre-install' "${rendered}"; then
  echo 'migration jobs must not run before their generated configuration exists' >&2
  exit 1
fi

if grep -q 'CHANGE_ME' "${rendered}"; then
  echo 'rendered manifests must not contain example secret placeholders' >&2
  exit 1
fi

if helm template test "${chart}" --set candlepin.replicas=2 >/dev/null 2>&1; then
  echo 'expected candlepin.replicas=2 to be rejected by the schema' >&2
  exit 1
fi

if helm template test "${chart}" --set pulp.controlProxy.replicas=1 >/dev/null 2>&1; then
  echo 'expected a single Pulp control proxy replica to be rejected by the schema' >&2
  exit 1
fi

if helm template test "${chart}" --set pulp.controlProxy.service.port=8443 >/dev/null 2>&1; then
  echo 'expected a non-standard Pulp control Service port to be rejected by the schema' >&2
  exit 1
fi

if helm template test "${chart}" --set foreman.autoscaling.maxReplicas=1 >/dev/null 2>&1; then
  echo 'expected an invalid autoscaling maximum to be rejected by the schema' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set foreman.autoscaling.enabled=true \
  --set foreman.autoscaling.minReplicas=5 \
  --set foreman.autoscaling.maxReplicas=2 >/dev/null 2>&1; then
  echo 'expected an inverted autoscaling range to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set networkPolicy.egress.enabled=true >/dev/null 2>&1; then
  echo 'expected restricted egress without database and Valkey peers to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --set networkPolicy.enabled=false >/dev/null 2>&1; then
  echo 'expected egress isolation with all NetworkPolicies disabled to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set backup.enabled=true \
  --set backup.requestId=20260924 >/dev/null 2>&1; then
  echo 'expected backup without maintenance mode to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set maintenance.enabled=true \
  --set restore.enabled=true \
  --set restore.requestId=20260924 \
  --set restore.confirmation=NO >/dev/null 2>&1; then
  echo 'expected restore without exact confirmation to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=20260924 \
  --set restore.enabled=true \
  --set restore.requestId=20260925 \
  --set restore.confirmation=RESTORE >/dev/null 2>&1; then
  echo 'expected simultaneous backup and restore to be rejected' >&2
  exit 1
fi

echo 'Helm render checks passed.'
