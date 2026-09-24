#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="${repo_root}/charts/foreman-stack"
execution_chart="${repo_root}/charts/foreman-execution-proxy"
operator_chart="${repo_root}/charts/foreman-release-operator"
rendered="$(mktemp)"
rendered_ingress="$(mktemp)"
rendered_execution_registration="$(mktemp)"
rendered_ingress_overrides="$(mktemp)"
rendered_minimal_pulp_ingress="$(mktemp)"
rendered_backup="$(mktemp)"
rendered_restore="$(mktemp)"
rendered_egress="$(mktemp)"
rendered_egress_backup="$(mktemp)"
rendered_egress_backup_local="$(mktemp)"
rendered_singletons="$(mktemp)"
rendered_ha="$(mktemp)"
rendered_candlepin_port="$(mktemp)"
rendered_foreman_service_port="$(mktemp)"
rendered_foreman_secret_contract="$(mktemp)"
rendered_database_tls_disabled="$(mktemp)"
rendered_image_pull_secrets="$(mktemp)"
rendered_no_migrations="$(mktemp)"
rendered_release_operation="$(mktemp)"
rendered_release_application="$(mktemp)"
rendered_manual_migration_stage="$(mktemp)"
rendered_secret_rotation="$(mktemp)"
rendered_monitoring="$(mktemp)"
rendered_monitoring_maintenance="$(mktemp)"
rendered_s3="$(mktemp)"
rendered_s3_backup="$(mktemp)"
rendered_smtp="$(mktemp)"
rendered_smtp_backup="$(mktemp)"
rendered_kind="$(mktemp)"
rendered_kind_backup="$(mktemp)"
rendered_execution="$(mktemp)"
rendered_execution_egress="$(mktemp)"
rendered_execution_kind="$(mktemp)"
rendered_execution_operation="$(mktemp)"
rendered_execution_secret_rotation="$(mktemp)"
rendered_execution_monitoring="$(mktemp)"
rendered_operator="$(mktemp)"
rendered_operator_monitoring="$(mktemp)"
rendered_operator_egress="$(mktemp)"
trap 'rm -f "${rendered}" "${rendered_ingress}" "${rendered_execution_registration}" "${rendered_ingress_overrides}" "${rendered_minimal_pulp_ingress}" "${rendered_backup}" "${rendered_restore}" "${rendered_egress}" "${rendered_egress_backup}" "${rendered_egress_backup_local}" "${rendered_singletons}" "${rendered_ha}" "${rendered_candlepin_port}" "${rendered_foreman_service_port}" "${rendered_foreman_secret_contract}" "${rendered_database_tls_disabled}" "${rendered_image_pull_secrets}" "${rendered_no_migrations}" "${rendered_release_operation}" "${rendered_release_application}" "${rendered_manual_migration_stage}" "${rendered_secret_rotation}" "${rendered_monitoring}" "${rendered_monitoring_maintenance}" "${rendered_s3}" "${rendered_s3_backup}" "${rendered_smtp}" "${rendered_smtp_backup}" "${rendered_kind}" "${rendered_kind_backup}" "${rendered_execution}" "${rendered_execution_egress}" "${rendered_execution_kind}" "${rendered_execution_operation}" "${rendered_execution_secret_rotation}" "${rendered_execution_monitoring}" "${rendered_operator}" "${rendered_operator_monitoring}" "${rendered_operator_egress}"' EXIT

ruby "${repo_root}/tests/yaml-duplicates.rb"
ruby "${repo_root}/tests/workflow-action-pins.rb" "${repo_root}/.github/workflows"
ruby "${repo_root}/tests/operator-contract.rb"
ruby "${repo_root}/tests/operator-crd-packaging.rb"
ruby "${repo_root}/tests/operator-state-machine.rb"
ruby "${repo_root}/tests/operator-reconciler.rb"
ruby "${repo_root}/tests/operator-controller.rb"
ruby "${repo_root}/tests/operator-command-runner.rb"
ruby "${repo_root}/tests/operator-health-server.rb"
ruby "${repo_root}/tests/operator-event-recorder.rb"
ruby "${repo_root}/tests/operator-leader-election.rb"
ruby "${repo_root}/tests/operator-kubernetes-client.rb"
ruby "${repo_root}/tests/operator-release-inputs.rb"
ruby "${repo_root}/tests/operator-lease-manager.rb"
ruby "${repo_root}/tests/operator-cluster-preflight.rb"
ruby "${repo_root}/tests/operator-runtime-adapter.rb"
ruby "${repo_root}/tests/values-schema-coverage.rb"
ruby "${repo_root}/tests/recovery-image-contract.rb"
ruby "${repo_root}/tests/operator-image-contract.rb"
ruby "${repo_root}/tests/kind-release-sequencing.rb"
bash "${repo_root}/tests/collect-diagnostics.sh"

helm lint "${chart}"
if helm lint "${chart}" --set pulp.workres.replicas=2 >/dev/null 2>&1; then
  echo 'values schema accepted an unknown Pulp key' >&2
  exit 1
fi
if helm lint "${chart}" --set-string releaseOperation.id=orphan-operation >/dev/null 2>&1; then
  echo 'release operation ID was accepted without its ForemanRelease owner UID' >&2
  exit 1
fi
helm template test "${chart}" > "${rendered}"
helm template test "${chart}" \
  --set monitoring.prometheusRule.enabled=true \
  --set-string monitoring.prometheusRule.labels.release=platform-monitoring > "${rendered_monitoring}"
helm template test "${chart}" \
  --set maintenance.enabled=true \
  --set monitoring.prometheusRule.enabled=true \
  --set-string monitoring.prometheusRule.labels.release=platform-monitoring > "${rendered_monitoring_maintenance}"
helm lint "${execution_chart}"
if helm lint "${execution_chart}" --set 'proxy.trsutedHosts[0]=foreman.example.test' >/dev/null 2>&1; then
  echo 'execution values schema accepted an unknown proxy key' >&2
  exit 1
fi
if helm lint "${execution_chart}" --set-string releaseOperation.id=orphan-operation >/dev/null 2>&1; then
  echo 'execution operation ID was accepted without its ForemanRelease owner UID' >&2
  exit 1
fi
if helm template execution "${execution_chart}" \
  --set terminationGracePeriodSeconds=30 \
  --set proxy.requestDrainSeconds=30 >/dev/null 2>&1; then
  echo 'execution proxy accepted a drain consuming its entire termination window' >&2
  exit 1
fi
helm template execution "${execution_chart}" > "${rendered_execution}"
helm template execution "${execution_chart}" \
  --set monitoring.prometheusRule.enabled=true \
  --set-string monitoring.prometheusRule.labels.release=platform-monitoring > "${rendered_execution_monitoring}"
helm lint "${operator_chart}"
helm template release-controller "${operator_chart}" --namespace foreman --include-crds > "${rendered_operator}"
helm template release-controller "${operator_chart}" --namespace foreman \
  --set monitoring.serviceMonitor.enabled=true \
  --set monitoring.prometheusRule.enabled=true \
  --set monitoring.grafanaDashboard.enabled=true \
  --set-string monitoring.serviceMonitor.labels.release=platform-monitoring \
  --set-string monitoring.prometheusRule.labels.release=platform-monitoring > "${rendered_operator_monitoring}"
if helm template release-controller "${operator_chart}" --namespace foreman \
  --set networkPolicy.egress.enabled=true >/dev/null 2>&1; then
  echo 'operator egress isolation accepted an unspecified Kubernetes API endpoint' >&2
  exit 1
fi
helm template release-controller "${operator_chart}" --namespace foreman \
  --set networkPolicy.egress.enabled=true \
  --set 'networkPolicy.egress.apiServer.peers[0].ipBlock.cidr=192.0.2.20/32' > "${rendered_operator_egress}"
if helm template release-controller "${operator_chart}" \
  --set controller.releaseLeaseDurationSeconds=240 >/dev/null 2>&1; then
  echo 'operator accepted a release Lease that can expire during bounded commands' >&2
  exit 1
fi
if helm template release-controller "${operator_chart}" \
  --set controller.commandTerminationGraceSeconds=60 >/dev/null 2>&1; then
  echo 'operator accepted a termination grace period longer than its command deadline' >&2
  exit 1
fi
if helm lint "${operator_chart}" --set serviceAccount.create=false >/dev/null 2>&1; then
  echo 'operator accepted an empty external service account name' >&2
  exit 1
fi
helm template execution "${execution_chart}" \
  --set-string releaseOperation.id=uid-123-generation-7 \
  --set-string releaseOperation.ownerUid=12345678-1234-1234-1234-123456789abc > "${rendered_execution_operation}"
helm template execution "${execution_chart}" \
  --set secretRolloutToken=rotated-credentials > "${rendered_execution_secret_rotation}"
helm lint "${execution_chart}" --values "${repo_root}/examples/execution-proxy-values.yaml"
helm lint "${execution_chart}" --values "${repo_root}/tests/execution-proxy-egress-values.yaml"
helm lint "${execution_chart}" \
  --values "${repo_root}/tests/kind/execution-proxy-values.yaml" \
  --values "${repo_root}/profiles/execution-proxy-nightly-candidate-2026-09-24.yaml"
helm template execution "${execution_chart}" \
  --values "${repo_root}/tests/execution-proxy-egress-values.yaml" > "${rendered_execution_egress}"
helm template execution "${execution_chart}" \
  --values "${repo_root}/tests/kind/execution-proxy-values.yaml" \
  --values "${repo_root}/profiles/execution-proxy-nightly-candidate-2026-09-24.yaml" > "${rendered_execution_kind}"
helm lint "${chart}" --values "${repo_root}/examples/cluster-values.yaml"
helm lint "${chart}" --values "${repo_root}/examples/execution-control-plane-values.yaml"
helm template test "${chart}" \
  --values "${repo_root}/examples/execution-control-plane-values.yaml" >/dev/null
helm template test "${chart}" --values "${repo_root}/examples/cluster-values.yaml" > "${rendered_ingress}"
helm template foreman "${chart}" \
  --values "${repo_root}/examples/cluster-values.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" > "${rendered_execution_registration}"
helm template test "${chart}" \
  --values "${repo_root}/examples/cluster-values.yaml" \
  --values "${repo_root}/tests/ingress-annotation-overrides.yaml" > "${rendered_ingress_overrides}"
helm template test "${chart}" \
  --values "${repo_root}/examples/cluster-values.yaml" \
  --set-json 'pulp.enabledPlugins=["pulp_certguard","pulp_file","pulp_smart_proxy"]' > "${rendered_minimal_pulp_ingress}"
helm lint "${chart}" --values "${repo_root}/tests/kind/values.yaml"
helm lint "${chart}" --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml"
helm lint "${chart}" --values "${repo_root}/tests/egress-values.yaml"
helm lint "${chart}" --values "${repo_root}/tests/ha-values.yaml"
helm lint "${chart}" --values "${repo_root}/examples/pulp-s3-values.yaml"
helm lint "${chart}" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --values "${repo_root}/tests/smtp-values.yaml"
helm lint "${chart}" \
  --values "${repo_root}/examples/cluster-values.yaml" \
  --values "${repo_root}/examples/candlepin-ha-values.yaml"
helm template foreman "${chart}" \
  --values "${repo_root}/tests/kind/values.yaml" \
  --values "${repo_root}/examples/execution-control-plane-values.yaml" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" > "${rendered_kind}"
helm template foreman "${chart}" \
  --values "${repo_root}/tests/kind/values.yaml" \
  --values "${repo_root}/examples/execution-control-plane-values.yaml" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=execution-escrow > "${rendered_kind_backup}"
if helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=mutable-image >/dev/null 2>&1; then
  echo 'expected recovery with a mutable toolbox image to be rejected' >&2
  exit 1
fi
if helm template test "${chart}" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=unqualified-release >/dev/null 2>&1; then
  echo 'expected recovery without a qualified compatibility set to be rejected' >&2
  exit 1
fi
helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=20260924-120000 > "${rendered_backup}"
helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set restore.enabled=true \
  --set restore.requestId=20260924-130000 \
  --set restore.confirmation=RESTORE > "${rendered_restore}"
helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --set foreman.service.port=3100 > "${rendered_egress}"
helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=egress-remote > "${rendered_egress_backup}"
helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=egress-local \
  --set recovery.repository.existingClaim=restic-repository > "${rendered_egress_backup_local}"
helm template test "${chart}" \
  --values "${repo_root}/tests/ha-values.yaml" > "${rendered_ha}"
helm template test "${chart}" \
  --set candlepin.service.port=24443 > "${rendered_candlepin_port}"
helm template test "${chart}" \
  --set foreman.service.port=3100 > "${rendered_foreman_service_port}"
helm template test "${chart}" \
  --set foreman.databaseUrlSecretKey=custom-database-url \
  --set foreman.encryptionKeySecretKey=custom-encryption-key \
  --set foreman.secretKeyBaseSecretKey=custom-secret-key-base \
  --set foreman.seedAdminUserSecretKey=custom-seed-user \
  --set foreman.seedAdminPasswordSecretKey=custom-seed-password > "${rendered_foreman_secret_contract}"
helm template test "${chart}" \
  --set foreman.database.sslMode=disable \
  --set foreman.existingDatabaseCaSecret= \
  --set candlepin.database.sslMode=disable \
  --set candlepin.existingDatabaseCaSecret= \
  --set pulp.database.sslMode=disable \
  --set pulp.existingDatabaseCaSecret= > "${rendered_database_tls_disabled}"
helm template test "${chart}" \
  --set 'imagePullSecrets[0].name=registry-auth' > "${rendered_image_pull_secrets}"
helm template test "${chart}" \
  --set migrations.enabled=false > "${rendered_no_migrations}"
helm template test "${chart}" \
  --set-string releaseOperation.id=uid-123-generation-7 \
  --set-string releaseOperation.ownerUid=12345678-1234-1234-1234-123456789abc > "${rendered_release_operation}"
helm template test "${chart}" \
  --set-string releaseOperation.id=uid-123-generation-7 \
  --set-string releaseOperation.ownerUid=12345678-1234-1234-1234-123456789abc \
  --set releaseOperation.skipMigrationJobs=true > "${rendered_release_application}"
ruby "${repo_root}/scripts/render-migration-stage.rb" test foreman \
  < "${rendered_release_operation}" > "${rendered_manual_migration_stage}"
helm template test "${chart}" \
  --set secretRolloutToken=rotated-credentials > "${rendered_secret_rotation}"
helm template test "${chart}" \
  --values "${repo_root}/examples/pulp-s3-values.yaml" > "${rendered_s3}"
helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/examples/pulp-s3-values.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=20260924-s3 > "${rendered_s3_backup}"
helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --values "${repo_root}/tests/smtp-values.yaml" > "${rendered_smtp}"
helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --values "${repo_root}/tests/smtp-values.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=smtp-escrow > "${rendered_smtp_backup}"
helm template test "${chart}" \
  --set foreman.replicas=1 \
  --set foreman.dynflow.workers=1 \
  --set foreman.dynflow.hostsQueueWorkers=1 \
  --set pulp.api.replicas=1 \
  --set pulp.content.replicas=1 \
  --set pulp.workers.replicas=1 > "${rendered_singletons}"

for manifest in \
  "${rendered}" \
  "${rendered_ingress}" \
  "${rendered_egress}" \
  "${rendered_egress_backup}" \
  "${rendered_egress_backup_local}" \
  "${rendered_singletons}" \
  "${rendered_ha}" \
  "${rendered_candlepin_port}" \
  "${rendered_foreman_service_port}" \
  "${rendered_no_migrations}" \
  "${rendered_release_operation}" \
  "${rendered_secret_rotation}" \
  "${rendered_s3}" \
  "${rendered_smtp}" \
  "${rendered_backup}" \
  "${rendered_restore}" \
  "${rendered_s3_backup}" \
  "${rendered_kind_backup}"; do
  ruby "${repo_root}/tests/kubernetes-invariants.rb" "${manifest}"
done

if ruby "${repo_root}/tests/kubernetes-invariants.rb" \
  "${repo_root}/tests/invalid-unbounded-network-policy.yaml" >/dev/null 2>&1; then
  echo 'Kubernetes invariants accepted an unbounded NetworkPolicy peer' >&2
  exit 1
fi

ruby "${repo_root}/tests/candlepin-port.rb" "${rendered_candlepin_port}" 24443
ruby "${repo_root}/tests/release-operation-contract.rb" \
  "${rendered_release_operation}" \
  uid-123-generation-7 \
  12345678-1234-1234-1234-123456789abc
ruby "${repo_root}/tests/operator-migration-staging-contract.rb" \
  "${rendered_release_operation}" "${rendered_release_application}"
ruby "${repo_root}/tests/manual-migration-staging-contract.rb" \
  "${rendered_manual_migration_stage}" uid-123-generation-7 test foreman
ruby "${repo_root}/tests/candlepin-shutdown-contract.rb" "${rendered}"
ruby "${repo_root}/tests/pulp-ingress-contract.rb" "${rendered_ingress}"
ruby "${repo_root}/tests/pulp-ingress-contract.rb" "${rendered_minimal_pulp_ingress}"
ruby "${repo_root}/tests/foreman-ingress-contract.rb" "${rendered_ingress}"
ruby "${repo_root}/tests/foreman-ingress-contract.rb" "${rendered_ingress_overrides}"
ruby "${repo_root}/tests/pulp-process-contract.rb" "${rendered}"
ruby "${repo_root}/tests/web-process-contract.rb" "${rendered}"
ruby "${repo_root}/tests/foreman-secret-contract.rb" \
  "${rendered_foreman_secret_contract}" \
  foreman-runtime \
  custom-database-url \
  custom-encryption-key \
  custom-secret-key-base \
  custom-seed-user \
  custom-seed-password
ruby "${repo_root}/tests/image-pull-secrets-contract.rb" \
  "${rendered_image_pull_secrets}" registry-auth
ruby "${repo_root}/tests/katello-event-daemon-contract.rb" "${rendered_egress}"
ruby "${repo_root}/tests/foreman-readiness-contract.rb" "${rendered}"
ruby "${repo_root}/tests/dynflow-lifecycle-contract.rb" "${rendered}"
ruby "${repo_root}/tests/backend-readiness-contract.rb" "${rendered}"
ruby "${repo_root}/tests/candlepin-migration-barrier.rb" "${rendered}" true
ruby "${repo_root}/tests/candlepin-migration-barrier.rb" "${rendered_no_migrations}" false
ruby "${repo_root}/tests/recurring-tasks-migration-barrier.rb" "${rendered}" true
ruby "${repo_root}/tests/recurring-tasks-migration-barrier.rb" "${rendered_no_migrations}" false
ruby "${repo_root}/tests/foreman-shared-tmp-contract.rb" "${rendered}" true
ruby "${repo_root}/tests/foreman-shared-tmp-contract.rb" "${rendered_s3}" false
ruby "${repo_root}/tests/foreman-database-pool-contract.rb" "${rendered}"
ruby "${repo_root}/tests/database-tls-contract.rb" "${rendered}" verify-full true
ruby "${repo_root}/tests/database-tls-contract.rb" "${rendered_database_tls_disabled}" disable false
ruby "${repo_root}/tests/valkey-contract.rb" "${rendered}" true
ruby "${repo_root}/tests/valkey-contract.rb" "${rendered_database_tls_disabled}" true
ruby "${repo_root}/tests/valkey-contract.rb" "${rendered_kind}" false
ruby "${repo_root}/tests/recovery-egress-contract.rb" "${rendered_egress_backup}" true
ruby "${repo_root}/tests/recovery-egress-contract.rb" "${rendered_egress_backup_local}" false
ruby "${repo_root}/tests/smoke-network-policy-contract.rb" "${rendered_egress}" 3100
ruby "${repo_root}/tests/smoke-network-policy-contract.rb" "${rendered_foreman_service_port}" 3100
ruby "${repo_root}/tests/disruption-budget-contract.rb" "${rendered}"
ruby "${repo_root}/tests/rollout-strategy-contract.rb" "${rendered}"
ruby "${repo_root}/tests/topology-spread-contract.rb" "${rendered}" ScheduleAnyway
ruby "${repo_root}/tests/topology-spread-contract.rb" "${rendered_ingress}" DoNotSchedule
ruby "${repo_root}/tests/smtp-contract.rb" "${rendered_smtp}" "${rendered_smtp_backup}"
ruby "${repo_root}/tests/recovery-storage-contract.rb" "${rendered_backup}" true
ruby "${repo_root}/tests/recovery-storage-contract.rb" "${rendered_restore}" true
ruby "${repo_root}/tests/recovery-storage-contract.rb" "${rendered_s3_backup}" false
ruby "${repo_root}/tests/secret-rollout-contract.rb" "${rendered}" "${rendered_secret_rotation}"

ruby "${repo_root}/tests/kubernetes-invariants.rb" "${rendered_execution}"
ruby "${repo_root}/tests/kubernetes-invariants.rb" "${rendered_execution_egress}"
ruby "${repo_root}/tests/kubernetes-invariants.rb" "${rendered_execution_kind}"
ruby "${repo_root}/tests/kubernetes-invariants.rb" "${rendered_execution_operation}"
ruby "${repo_root}/tests/kubernetes-invariants.rb" "${rendered_execution_secret_rotation}"
ruby "${repo_root}/tests/execution-release-operation-contract.rb" \
  "${rendered_execution_operation}" \
  uid-123-generation-7 \
  12345678-1234-1234-1234-123456789abc
ruby "${repo_root}/tests/execution-smoke-contract.rb" "${rendered_execution}"
ruby "${repo_root}/tests/execution-registration-contract.rb" "${rendered_execution_registration}"
ruby "${repo_root}/tests/secret-rollout-contract.rb" \
  "${rendered_execution}" "${rendered_execution_secret_rotation}"
ruby "${repo_root}/tests/kubernetes-invariants.rb" "${rendered_operator}"
ruby "${repo_root}/tests/kubernetes-invariants.rb" "${rendered_operator_egress}"
ruby "${repo_root}/tests/operator-chart-contract.rb" "${rendered_operator}"
ruby "${repo_root}/tests/operator-egress-contract.rb" "${rendered_operator_egress}"
ruby "${repo_root}/tests/operator-rbac-coverage.rb" \
  "${rendered_operator}" "${rendered_ingress}" "${rendered_monitoring}" \
  "${rendered_execution_monitoring}"
ruby "${repo_root}/tests/operator-monitoring-contract.rb" \
  "${rendered_operator}" "${rendered_operator_monitoring}"
ruby "${repo_root}/tests/workload-monitoring-contract.rb" \
  "${rendered}" "${rendered_monitoring}" "${rendered_monitoring_maintenance}" \
  "${rendered_execution}" "${rendered_execution_monitoring}"
ruby -c "${execution_chart}/files/check-features.rb"

grep -q 'name: FOREMAN_PROXY_ENABLED_PLUGINS' "${rendered_execution}"
grep -A1 'command:' "${rendered_execution}" | grep -q '/usr/share/foreman-proxy/bin/smart-proxy'
grep -A5 'preStop:' "${rendered_execution}" | grep -q '/usr/bin/sleep'
grep -A5 'preStop:' "${rendered_execution}" | grep -Eq -- '- "?10"?'
grep -A1 'name: FOREMAN_PROXY_ENABLED_PLUGINS' "${rendered_execution}" | \
  grep -q 'value: remote_execution_ssh ansible'
grep -q 'expected = %w\[ansible dynflow script\]' "${rendered_execution}"
grep -q 'unexpected Smart Proxy features' "${rendered_execution}"
grep -q "http.verify_mode = OpenSSL::SSL::VERIFY_PEER" "${rendered_execution}"
if grep -q 'OpenSSL::SSL::VERIFY_NONE' "${rendered_execution}"; then
  echo 'execution proxy readiness must verify the local server certificate' >&2
  exit 1
fi
grep -q ':database: /var/lib/foreman-proxy/dynflow/dynflow.sqlite' "${rendered_execution}"
grep -q ':cockpit_integration: false' "${rendered_execution}"
grep -q 'readOnlyRootFilesystem: true' "${rendered_execution}"
grep -q 'runAsUser: 991' "${rendered_execution}"
grep -q 'mountPath: /etc/ansible' "${rendered_execution}"
grep -q 'mountPath: /var/lib/foreman-proxy' "${rendered_execution}"
grep -q 'mountPath: /var/run/foreman-proxy/ssh' "${rendered_execution}"
grep -q 'install -m 0600 /ssh-source/private' "${rendered_execution}"
grep -q ':ssh_ca_known_hosts_file: /etc/foreman-proxy/ssh-host-keys/known_hosts' "${rendered_execution}"
grep -q 'ANSIBLE_HOST_KEY_CHECKING="True"' "${rendered_execution}"
grep -q 'type: ClusterIP' "${rendered_execution}"
grep -q 'app.kubernetes.io/instance: foreman' "${rendered_execution}"
if grep -q 'hostNetwork:' "${rendered_execution}"; then
  echo 'execution proxy must not use the host network' >&2
  exit 1
fi
if grep -q 'privileged: true' "${rendered_execution}"; then
  echo 'execution proxy must not be privileged' >&2
  exit 1
fi
if [[ "$(grep -c '^kind: Deployment$' "${rendered_execution}")" -ne 1 ]]; then
  echo 'execution proxy profile must contain one Deployment' >&2
  exit 1
fi
grep -q 'cidr: 192.0.2.10/32' "${rendered_execution_egress}"
grep -q 'cidr: 198.51.100.0/24' "${rendered_execution_egress}"
grep -q 'port: 443' "${rendered_execution_egress}"
grep -q 'port: 2222' "${rendered_execution_egress}"
grep -q ':ssh_user_ca_public_key_file: /var/run/foreman-proxy/ssh/ssh-user-ca.pub' "${rendered_execution_egress}"
grep -q ':ssh_ca_known_hosts_file: /etc/foreman-proxy/ssh-host-keys/known_hosts' "${rendered_execution_egress}"
grep -q 'ANSIBLE_HOST_KEY_CHECKING="True"' "${rendered_execution_egress}"
grep -Fq 'quay.io/foreman/foreman-proxy:nightly@sha256:244c756844a137990779ad153998c426eb0326d8d6f376192ea6e84947affd47' "${rendered_execution_kind}"
grep -Fq ':foreman_url: "https://foreman.test"' "${rendered_execution_kind}"
grep -Fq 'claimName: execution-ansible-content' "${rendered_execution_kind}"
grep -q '^    - Egress$' "${rendered_execution_kind}"
grep -q 'kubernetes.io/metadata.name: ingress-nginx' "${rendered_execution_kind}"
grep -q 'app.kubernetes.io/instance: ingress-nginx' "${rendered_execution_kind}"
grep -q 'app: execution-target' "${rendered_execution_kind}"
grep -q 'port: 8443' "${rendered_execution_kind}"
if grep -q 'cidr: 0.0.0.0/0' "${rendered_execution_kind}"; then
  echo 'kind execution proxy must not receive unrestricted egress' >&2
  exit 1
fi

if helm template execution "${execution_chart}" --set replicas=2 >/dev/null 2>&1; then
  echo 'expected multiple execution proxy replicas to be rejected' >&2
  exit 1
fi

if helm template execution "${execution_chart}" \
  --set ssh.hostKeyVerification.enabled=false >/dev/null 2>&1; then
  echo 'expected insecure host-key checking without acknowledgement to be rejected' >&2
  exit 1
fi

helm template execution "${execution_chart}" \
  --set ssh.hostKeyVerification.enabled=false \
  --set-string ssh.hostKeyVerification.insecureSkipVerificationAcknowledgement=I_UNDERSTAND_HOST_KEYS_ARE_NOT_VERIFIED |
  grep -q 'ANSIBLE_HOST_KEY_CHECKING="False"'

if helm template execution "${execution_chart}" \
  --set networkPolicy.egress.enabled=true >/dev/null 2>&1; then
  echo 'expected restricted proxy egress without declared peers to be rejected' >&2
  exit 1
fi

shellcheck -x \
  -P "${chart}/files" \
  "${chart}/files/recovery-common.sh" \
  "${chart}/files/backup.sh" \
  "${chart}/files/restore.sh" \
  "${chart}/files/candlepin-migrate.sh"
shellcheck -x \
  -P "${repo_root}/scripts" \
  "${repo_root}/scripts/release-preflight.sh" \
  "${repo_root}/scripts/install-release.sh" \
  "${repo_root}/scripts/upgrade-release.sh" \
  "${repo_root}/scripts/recover-release.sh" \
  "${repo_root}/scripts/collect-diagnostics.sh" \
  "${repo_root}/tests/install-release.sh" \
  "${repo_root}/tests/upgrade-release.sh" \
  "${repo_root}/tests/recover-release.sh" \
  "${repo_root}/tests/kind/execution-plane.sh" \
  "${repo_root}/tests/kind/publish-ansible-content.sh" \
  "${repo_root}/tests/kind/run.sh"
shellcheck "${repo_root}/tests/recovery-quiescence.sh"
shellcheck "${repo_root}/tests/recovery-integrity.sh"
shellcheck "${repo_root}/tests/collect-diagnostics.sh"
"${repo_root}/tests/recovery-integrity.sh"

ruby "${repo_root}/tests/plugin-compatibility.rb"
ruby "${repo_root}/tests/release-sets.rb"
ruby -c "${repo_root}/scripts/write-integration-evidence.rb"
ruby -c "${repo_root}/scripts/promote-release-set.rb"
ruby -c "${repo_root}/scripts/required-cluster-resources.rb"
ruby -c "${repo_root}/scripts/required-secrets.rb"
ruby -c "${repo_root}/scripts/render-migration-stage.rb"
ruby -c "${repo_root}/tests/integration-evidence.rb"
ruby -c "${repo_root}/tests/operator-contract.rb"
ruby -c "${chart}/files/foreman-readiness.rb"
ruby "${repo_root}/tests/foreman-readiness-behavior.rb"
ruby "${repo_root}/tests/dynflow-lifecycle-behavior.rb"
python3 "${repo_root}/tests/pulp-readiness-behavior.py"
python3 -c 'import pathlib; source = pathlib.Path(__import__("sys").argv[1]).read_text(); compile(source, __import__("sys").argv[1], "exec")' \
  "${chart}/files/pulp-app-readiness.py"
ruby "${repo_root}/tests/integration-evidence.rb"
ruby "${repo_root}/tests/required-cluster-resources.rb"
ruby "${repo_root}/tests/required-secrets.rb"
"${repo_root}/tests/recovery-quiescence.sh"
"${repo_root}/tests/install-release.sh"
"${repo_root}/tests/upgrade-release.sh"
"${repo_root}/tests/recover-release.sh"

grep -Fq \
  'apache/artemis:2.57.0-alpine@sha256:ca99ce1b72c5765a15dd507db4215591c43da623cd9f42db1bcd4319e5f4b579' \
  "${repo_root}/tests/kind/dependencies.yaml"
grep -Fq -- "--from-literal=artemis-broker-url='tcp://artemis:61616'" \
  "${repo_root}/tests/kind/apply-secrets.sh"
grep -Fq \
  'alpine:3.22@sha256:3e9b4b680bfc9fb5269227cffbd6d42be39fbf7c0b908123913864aa4447e764' \
  "${repo_root}/images/ssh-target/Dockerfile"
grep -Fq "expected 'Ansible,Dynflow,Script'" \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq '/ansible/api/v2/ansible_roles/sync' \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq '/play_roles' "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq '/cancel' "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq 'expected failure' "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq 'Execution proxy reached an undeclared in-cluster destination' \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq 'foreman_kubernetes_content_revision' \
  "${repo_root}/tests/kind/publish-ansible-content.sh"
grep -Fq 'foreman-kubernetes-role-{{ foreman_kubernetes_content_revision }}-ok' \
  "${repo_root}/tests/kind/publish-ansible-content.sh"
grep -Fq 'claimName: execution-ansible-content' \
  "${repo_root}/tests/kind/execution-ansible-content-job.yaml"
grep -Fq 'EXPECTED_ROLE_REVISION' \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq 'Ansible role executed stale content revision' \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq 'TEST_PROXY_INTERRUPTION' \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq 'EXECUTION_SCENARIO' \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq 'assert_interrupted_job_recovery' \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq 'start_upgrade_job' \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq "wait_for_task \"\${task_id}\" success" \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq -- '--grace-period=0' \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq 'foreman-kubernetes-after-proxy-restart-ok' \
  "${repo_root}/tests/kind/execution-plane.sh"
grep -Fq "if [[ ! -s \"\${workdir}/ca.crt\" ]]" \
  "${repo_root}/tests/kind/apply-secrets.sh"
grep -Fq 'foreman-execution-proxy-tls' "${rendered_kind_backup}"
grep -Fq 'foreman-execution-proxy-foreman-client' "${rendered_kind_backup}"
grep -Fq 'foreman-execution-proxy-ssh' "${rendered_kind_backup}"
grep -Fq 'platform.theforeman.org/compatibility-set: "nightly-candidate-2026-09-24"' "${rendered_kind}"
grep -Fq 'platform.theforeman.org/compatibility-set: "nightly-candidate-2026-09-24"' "${rendered_execution_kind}"
grep -Fq 'rotate_execution_identity' "${repo_root}/tests/kind/run.sh"
grep -Fq 'publish-ansible-content.sh" v2' "${repo_root}/tests/kind/run.sh"
grep -Fq 'assert_execution_plane v2' "${repo_root}/tests/kind/run.sh"
grep -Fq 'assert_execution_plane v1 1' "${repo_root}/tests/kind/run.sh"
grep -Fq 'start_execution_upgrade_job application-upgrade' \
  "${repo_root}/tests/kind/run.sh"
grep -Fq 'finish_execution_upgrade_job application-upgrade' \
  "${repo_root}/tests/kind/run.sh"
grep -Fq 'start_execution_upgrade_job proxy-upgrade' \
  "${repo_root}/tests/kind/run.sh"
grep -Fq 'finish_execution_upgrade_job proxy-upgrade' \
  "${repo_root}/tests/kind/run.sh"
grep -Fq 'assert_pods_replaced' "${repo_root}/tests/kind/run.sh"
grep -Fq 'assert_failed_migration_gate' "${repo_root}/tests/kind/run.sh"
grep -Fq 'assert_pods_unchanged' "${repo_root}/tests/kind/run.sh"
grep -Fq 'wrong-password@postgresql' "${repo_root}/tests/kind/run.sh"
grep -Fq 'restore_foreman_database_url' "${repo_root}/tests/kind/run.sh"
grep -Fq 'write_integration_evidence' "${repo_root}/tests/kind/run.sh"
grep -Fq 'compatibility/release-sets.json' "${repo_root}/tests/kind/run.sh"
grep -Fq -- '-purpose sslserver' "${repo_root}/tests/kind/run.sh"
grep -Fq -- '-purpose sslclient' "${repo_root}/tests/kind/run.sh"

grep -q 'name: test-foreman-stack-foreman' "${rendered}"
grep -q 'name: test-foreman-stack-candlepin' "${rendered}"
grep -q 'name: test-foreman-stack-dynflow-orchestrator' "${rendered}"
grep -q 'name: test-foreman-stack-pulp-worker' "${rendered}"
grep -q 'name: test-foreman-stack-katello-event-daemon' "${rendered}"
RUBY_RENDERED_MANIFEST="${rendered}" ruby <<'RUBY'
require 'yaml'

deployments = YAML.load_stream(File.read(ENV.fetch('RUBY_RENDERED_MANIFEST'))).compact.select do |resource|
  resource['kind'] == 'Deployment' && resource.dig('metadata', 'name')&.include?('-dynflow-')
end
abort "expected three Dynflow deployments, got #{deployments.length}" unless deployments.length == 3
abort 'Dynflow deployment is missing its configuration checksum' unless deployments.all? do |deployment|
  deployment.dig('spec', 'template', 'metadata', 'annotations', 'checksum/config')
end
RUBY
grep -q 'name: test-foreman-stack-smoke-test' "${rendered}"
grep -q 'helm.sh/hook: test' "${rendered}"
grep -q 'CANDLEPIN_STATUS_URL' "${rendered}"
grep -q 'PULP_STATUS_URL' "${rendered}"
grep -q "client.verify_mode = OpenSSL::SSL::VERIFY_PEER" "${rendered}"
if [[ "$(grep -c 'app.kubernetes.io/component: smoke-test' "${rendered}")" -lt 4 ]]; then
  echo 'smoke test must be permitted by each tested service network policy' >&2
  exit 1
fi
grep -q '^kind: PersistentVolumeClaim$' "${rendered}"
grep -q 'mountPath: /var/lib/pulp$' "${rendered}"
grep -q 'replicas: 1' "${rendered}"
grep -q 'name: test-foreman-stack-foreman-config' "${rendered}"
grep -q 'CANDLEPIN_AUTH_OAUTH_CONSUMER_KATELLO_SECRET' "${rendered}"
grep -q 'JPA_CONFIG_HIBERNATE_CONNECTION_PASSWORD' "${rendered}"
grep -q 'PULP_DATABASES__default__PASSWORD' "${rendered}"
grep -q "ENV.fetch('CANDLEPIN_OAUTH_SECRET')" "${rendered}"
grep -q 'name: wait-for-pulp-migrations' "${rendered}"
grep -q 'name: wait-for-foreman-migrations' "${rendered}"
grep -q 'name: test-foreman-stack-candlepin-migrate-1' "${rendered}"
grep -q 'candlepin.db.database_manage_on_startup=HALT' "${rendered}"
grep -q 'name: LIQUIBASE_COMMAND_PASSWORD' "${rendered}"
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
grep -q 'path: /pulp/deb' "${rendered_ingress}"
if grep -q 'path: /pulp_ansible/galaxy' "${rendered_ingress}"; then
  echo 'disabled pulp_ansible must not publish a Galaxy endpoint' >&2
  exit 1
fi
if [[ "$(grep -c '^kind: HorizontalPodAutoscaler$' "${rendered_ingress}")" -ne 3 ]]; then
  echo 'expected Foreman, Pulp API, and Pulp content autoscalers' >&2
  exit 1
fi
grep -q 'whenUnsatisfiable: DoNotSchedule' "${rendered_ingress}"
grep -q 'whenUnsatisfiable: ScheduleAnyway' "${rendered}"
grep -q 'name: test-foreman-stack-pulp-api' "${rendered}"
grep -q 'kind: NetworkPolicy' "${rendered}"
grep -q 'app.kubernetes.io/component: pulp-control-proxy' "${rendered}"
grep -q 'automountServiceAccountToken: false' "${rendered}"
grep -q 'runAsUser: 994' "${rendered}"
grep -q 'runAsUser: 700' "${rendered}"
grep -q 'type: RuntimeDefault' "${rendered}"
grep -q 'name: test-foreman-stack-dynflow-worker' "${rendered}"
if [[ "$(grep -c 'startupProbe:' "${rendered}")" -ne 9 ]]; then
  echo 'expected startup probes for Foreman, Dynflow, Katello events, Candlepin, Pulp API/content, and the Pulp control proxy' >&2
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
grep -A5 'readinessProbe:' "${rendered}" | grep -q '/opt/foreman-kubernetes/foreman-readiness.rb'
grep -q 'GET /candlepin/status HTTP/1.1' "${rendered}"
grep -q '/opt/foreman-kubernetes/pulp-readiness.py' "${rendered}"
grep -q "Katello dependencies are not healthy" "${rendered}"
grep -q "Candlepin mode is" "${rendered}"
grep -q "Pulp has no online workers" "${rendered}"
grep -Fq 'assert_application_smoke_test' "${repo_root}/tests/kind/run.sh"

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
ruby "${repo_root}/tests/disruption-budget-contract.rb" "${rendered_singletons}"

if [[ "$(grep -c '^    - Egress$' "${rendered_egress}")" -ne 5 ]]; then
  echo 'expected component-scoped Foreman, Pulp, Candlepin, control-proxy, and smoke-test egress policies' >&2
  exit 1
fi
grep -q 'cidr: 192.0.2.10/32' "${rendered_egress}"
grep -q 'cidr: 192.0.2.11/32' "${rendered_egress}"
grep -q 'cidr: 198.51.100.0/24' "${rendered_egress}"
grep -q 'cidr: 203.0.113.0/24' "${rendered_egress}"

grep -q '^  replicas: 2$' "${rendered_ha}"
grep -q 'candlepin.audit.hornetq.embedded=false' "${rendered_ha}"
grep -q 'candlepin.messaging.activemq.embedded.enabled=false' "${rendered_ha}"
grep -q 'org.quartz.scheduler.instanceId=AUTO' "${rendered_ha}"
grep -q 'org.quartz.jobStore.isClustered=true' "${rendered_ha}"
grep -q 'org.quartz.jobStore.clusterCheckinInterval=15000' "${rendered_ha}"
grep -q 'name: CANDLEPIN_AUDIT_HORNETQ_BROKER_URL' "${rendered_ha}"
grep -q 'key: artemis-broker-url' "${rendered_ha}"
grep -q 'secretName: candlepin-artemis-tls' "${rendered_ha}"
grep -q 'cidr: 192.0.2.12/32' "${rendered_ha}"
if [[ "$(grep -c '^kind: PodDisruptionBudget$' "${rendered_ha}")" -ne 7 ]]; then
  echo 'expected a Candlepin disruption budget only in the redundant HA profile' >&2
  exit 1
fi

grep -q 'name: PULP_STORAGES__default__BACKEND' "${rendered_s3}"
grep -q 'value: storages.backends.s3.S3Storage' "${rendered_s3}"
grep -q 'name: PULP_STORAGES__default__OPTIONS__bucket_name' "${rendered_s3}"
grep -Eq 'value: "?foreman-pulp"?' "${rendered_s3}"
grep -q 'name: PULP_STORAGES__default__OPTIONS__location' "${rendered_s3}"
grep -q 'name: PULP_STORAGES__default__OPTIONS__endpoint_url' "${rendered_s3}"
grep -q 'name: PULP_REDIRECT_TO_OBJECT_STORAGE' "${rendered_s3}"
grep -q 'name: PULP_STORAGES__default__OPTIONS__access_key' "${rendered_s3}"
if [[ "$(grep -c 'name: PULP_STORAGES__default__OPTIONS__access_key' "${rendered_s3}")" -ne 3 ]]; then
  echo 'static object credentials must be exposed only to the three Pulp runtime roles' >&2
  exit 1
fi
grep -q 'name: pulp-object-storage-ca' "${rendered_s3}"
grep -q 'mountPath: /etc/pulp/object-storage/ca.crt' "${rendered_s3}"
grep -q 'mountPath: /var/lib/pulp/tmp' "${rendered_s3}"
grep -q 'sizeLimit: 20Gi' "${rendered_s3}"
grep -q 'eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/foreman-pulp' "${rendered_s3}"
if [[ "$(grep -c 'serviceAccountName: test-foreman-stack-pulp$' "${rendered_s3}")" -ne 3 ]]; then
  echo 'only Pulp API, content, and worker Deployments should use the object-storage identity' >&2
  exit 1
fi
grep -q 'name: PULP_STORAGE_BACKEND' "${rendered_s3_backup}"
grep -A1 'name: PULP_STORAGE_BACKEND' "${rendered_s3_backup}" | grep -Eq 'value: "?s3"?'
grep -q -- '- pulp-object-storage$' "${rendered_s3_backup}"
grep -q -- '- pulp-object-storage-ca$' "${rendered_s3_backup}"

grep -q 'app.kubernetes.io/component: recovery-backup' "${rendered_backup}"
grep -q 'name: BACKUP_REQUEST_ID' "${rendered_backup}"
grep -q 'name: RESTIC_CACHE_DIR' "${rendered_backup}"
grep -A1 'name: COMPATIBILITY_SET' "${rendered_backup}" | \
  grep -Eq 'value: "?nightly-candidate-2026-09-24"?'
grep -q 'resourceNames:' "${rendered_backup}"
grep -q 'name: test-foreman-stack-backup-20260924-120000' "${rendered_backup}"
ruby "${repo_root}/scripts/required-secrets.rb" < "${rendered_backup}" |
  grep -Fq $'foreman-backup-repository\tRESTIC_PASSWORD,RESTIC_REPOSITORY'
ruby "${repo_root}/scripts/required-secrets.rb" < "${rendered_kind_backup}" |
  grep -Fq $'foreman-backup-repository\tRESTIC_PASSWORD'
if ruby "${repo_root}/scripts/required-secrets.rb" < "${rendered_kind_backup}" |
  grep -Fq 'RESTIC_REPOSITORY'; then
  echo 'local recovery repository unexpectedly requires RESTIC_REPOSITORY in its Secret' >&2
  exit 1
fi
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
  echo 'expected multiple Candlepin replicas without the HA contract to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set candlepin.shutdown.terminationGracePeriodSeconds=600 >/dev/null 2>&1; then
  echo 'expected an undersized Candlepin shutdown window to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/tests/ha-values.yaml" \
  --set migrations.enabled=false >/dev/null 2>&1; then
  echo 'expected Candlepin HA without migration ownership to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --set candlepin.replicas=2 \
  --set candlepin.highAvailability.enabled=true >/dev/null 2>&1; then
  echo 'expected restricted Candlepin HA without an Artemis egress peer to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set pulp.storage.backend=s3 >/dev/null 2>&1; then
  echo 'expected object storage without a bucket to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set-json 'foreman.enabledPlugins=["foreman-tasks","katello","foreman_ansible"]' >/dev/null 2>&1; then
  echo 'expected unverified Foreman plugins to require an explicit policy override' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set foreman.pluginPolicy.allowUnverified=true \
  --set-json 'foreman.enabledPlugins=["foreman-tasks","katello","foreman_ansible"]' >/dev/null 2>&1; then
  echo 'expected Foreman Ansible to require the Remote Execution plugin' >&2
  exit 1
fi

helm template test "${chart}" \
  --set foreman.pluginPolicy.allowUnverified=true \
  --set-json 'foreman.enabledPlugins=["foreman-tasks","katello","foreman_remote_execution","foreman_ansible"]' >/dev/null

if helm template test "${chart}" --set smartProxy.mode=embedded >/dev/null 2>&1; then
  echo 'expected embedded Smart Proxy mode to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/tests/s3-egress-missing-values.yaml" >/dev/null 2>&1; then
  echo 'expected restricted object storage without an S3 egress peer to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/examples/pulp-s3-values.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set restore.enabled=true \
  --set restore.requestId=20260924-s3 \
  --set restore.confirmation=RESTORE >/dev/null 2>&1; then
  echo 'expected S3 restore without a coordinated bucket confirmation to be rejected' >&2
  exit 1
fi

helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/examples/pulp-s3-values.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set restore.enabled=true \
  --set restore.requestId=20260924-s3 \
  --set restore.confirmation=RESTORE \
  --set restore.objectStorageConfirmation=BUCKET_RESTORED >/dev/null

if helm template test "${chart}" \
  --set candlepin.highAvailability.enabled=true >/dev/null 2>&1; then
  echo 'expected Candlepin HA with only one replica to be rejected' >&2
  exit 1
fi

if ! grep -q 'candlepin.db.database_manage_on_startup=Manage' "${rendered_no_migrations}"; then
  echo 'Candlepin must retain upstream startup migration ownership when chart migrations are disabled' >&2
  exit 1
fi

if grep -q 'name: test-foreman-stack-candlepin-migrate-1' "${rendered_no_migrations}"; then
  echo 'Candlepin migration resources must be omitted when chart migrations are disabled' >&2
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
  --set foreman.databasePools.web=4 >/dev/null 2>&1; then
  echo 'expected a web database pool smaller than Puma concurrency to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set foreman.existingDatabaseCaSecret= >/dev/null 2>&1; then
  echo 'expected Foreman certificate verification without a database CA to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set valkey.tls.existingCaSecret= >/dev/null 2>&1; then
  echo 'expected Valkey TLS without a CA to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set valkey.tls.enabled=false >/dev/null 2>&1; then
  echo 'expected a Valkey CA to be rejected when TLS is disabled' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set candlepin.existingDatabaseCaSecret= >/dev/null 2>&1; then
  echo 'expected Candlepin certificate verification without a database CA to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set pulp.existingDatabaseCaSecret= >/dev/null 2>&1; then
  echo 'expected Pulp certificate verification without a database CA to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set foreman.databasePools.dynflowWorker=9 >/dev/null 2>&1; then
  echo 'expected a Dynflow database pool smaller than Sidekiq concurrency to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set foreman.puma.threadsMin=6 >/dev/null 2>&1; then
  echo 'expected Puma minimum threads greater than maximum threads to be rejected' >&2
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
  --set pulp.api.requestDrainSeconds=40 \
  --set pulp.api.gunicornGracefulTimeoutSeconds=120 \
  --set pulp.api.terminationGracePeriodSeconds=150 >/dev/null 2>&1; then
  echo 'expected a Pulp shutdown window shorter than drain plus graceful timeout to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set networkPolicy.egress.enabled=true >/dev/null 2>&1; then
  echo 'expected restricted egress without database and Valkey peers to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --set foreman.email.enabled=true >/dev/null 2>&1; then
  echo 'expected enabled email without an SMTP address to be rejected' >&2
  exit 1
fi

helm template test "${chart}" \
  --set foreman.email.enabled=true \
  --set foreman.email.smtp.address=smtp.example.test \
  --set foreman.email.smtp.authentication=none >/dev/null

if helm template test "${chart}" \
  --set foreman.email.enabled=true \
  --set foreman.email.smtp.address=smtp.example.test \
  --set foreman.email.smtp.authentication=login >/dev/null 2>&1; then
  echo 'expected authenticated SMTP without a Secret to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --values "${repo_root}/tests/smtp-values.yaml" \
  --set-json 'networkPolicy.egress.external.smtp.peers=[]' >/dev/null 2>&1; then
  echo 'expected restricted email without an SMTP relay peer to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --set networkPolicy.enabled=false >/dev/null 2>&1; then
  echo 'expected egress isolation with all NetworkPolicies disabled to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=missing-api \
  --set-json 'networkPolicy.egress.recovery.apiServer.peers=[]' >/dev/null 2>&1; then
  echo 'expected restricted recovery without a Kubernetes API peer to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=missing-repository \
  --set-json 'networkPolicy.egress.recovery.repository.peers=[]' >/dev/null 2>&1; then
  echo 'expected remote recovery without a Restic repository peer to be rejected' >&2
  exit 1
fi

helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/egress-values.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=local-repository \
  --set recovery.repository.existingClaim=restic-repository \
  --set-json 'networkPolicy.egress.recovery.repository.peers=[]' >/dev/null

if helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set backup.enabled=true \
  --set backup.requestId=20260924 >/dev/null 2>&1; then
  echo 'expected backup without maintenance mode to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
  --set maintenance.enabled=true \
  --set restore.enabled=true \
  --set restore.requestId=20260924 \
  --set restore.confirmation=NO >/dev/null 2>&1; then
  echo 'expected restore without exact confirmation to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --values "${repo_root}/tests/recovery-image-values.yaml" \
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
