#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
chart="${repo_root}/charts/foreman-stack"
execution_chart="${repo_root}/charts/foreman-execution-proxy"
rendered="$(mktemp)"
rendered_ingress="$(mktemp)"
rendered_backup="$(mktemp)"
rendered_restore="$(mktemp)"
rendered_egress="$(mktemp)"
rendered_singletons="$(mktemp)"
rendered_ha="$(mktemp)"
rendered_candlepin_port="$(mktemp)"
rendered_foreman_service_port="$(mktemp)"
rendered_no_migrations="$(mktemp)"
rendered_secret_rotation="$(mktemp)"
rendered_s3="$(mktemp)"
rendered_s3_backup="$(mktemp)"
rendered_kind_backup="$(mktemp)"
rendered_execution="$(mktemp)"
rendered_execution_egress="$(mktemp)"
rendered_execution_kind="$(mktemp)"
rendered_execution_secret_rotation="$(mktemp)"
trap 'rm -f "${rendered}" "${rendered_ingress}" "${rendered_backup}" "${rendered_restore}" "${rendered_egress}" "${rendered_singletons}" "${rendered_ha}" "${rendered_candlepin_port}" "${rendered_foreman_service_port}" "${rendered_no_migrations}" "${rendered_secret_rotation}" "${rendered_s3}" "${rendered_s3_backup}" "${rendered_kind_backup}" "${rendered_execution}" "${rendered_execution_egress}" "${rendered_execution_kind}" "${rendered_execution_secret_rotation}"' EXIT

ruby "${repo_root}/tests/yaml-duplicates.rb"
ruby "${repo_root}/tests/operator-contract.rb"

helm lint "${chart}"
helm template test "${chart}" > "${rendered}"
helm lint "${execution_chart}"
helm template execution "${execution_chart}" > "${rendered_execution}"
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
helm lint "${chart}" --values "${repo_root}/tests/kind/values.yaml"
helm lint "${chart}" --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml"
helm lint "${chart}" --values "${repo_root}/tests/egress-values.yaml"
helm lint "${chart}" --values "${repo_root}/tests/ha-values.yaml"
helm lint "${chart}" --values "${repo_root}/examples/pulp-s3-values.yaml"
helm lint "${chart}" \
  --values "${repo_root}/examples/cluster-values.yaml" \
  --values "${repo_root}/examples/candlepin-ha-values.yaml"
helm template foreman "${chart}" \
  --values "${repo_root}/tests/kind/values.yaml" \
  --values "${repo_root}/examples/execution-control-plane-values.yaml" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" >/dev/null
helm template foreman "${chart}" \
  --values "${repo_root}/tests/kind/values.yaml" \
  --values "${repo_root}/examples/execution-control-plane-values.yaml" \
  --values "${repo_root}/profiles/nightly-candidate-2026-09-23.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=execution-escrow > "${rendered_kind_backup}"
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
  --values "${repo_root}/tests/ha-values.yaml" > "${rendered_ha}"
helm template test "${chart}" \
  --set candlepin.service.port=24443 > "${rendered_candlepin_port}"
helm template test "${chart}" \
  --set foreman.service.port=3100 > "${rendered_foreman_service_port}"
helm template test "${chart}" \
  --set migrations.enabled=false > "${rendered_no_migrations}"
helm template test "${chart}" \
  --set secretRolloutToken=rotated-credentials > "${rendered_secret_rotation}"
helm template test "${chart}" \
  --values "${repo_root}/examples/pulp-s3-values.yaml" > "${rendered_s3}"
helm template test "${chart}" \
  --values "${repo_root}/examples/pulp-s3-values.yaml" \
  --set maintenance.enabled=true \
  --set backup.enabled=true \
  --set backup.requestId=20260924-s3 > "${rendered_s3_backup}"
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
  "${rendered_singletons}" \
  "${rendered_ha}" \
  "${rendered_candlepin_port}" \
  "${rendered_foreman_service_port}" \
  "${rendered_no_migrations}" \
  "${rendered_secret_rotation}" \
  "${rendered_s3}" \
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
ruby "${repo_root}/tests/pulp-ingress-contract.rb" "${rendered_ingress}"
ruby "${repo_root}/tests/pulp-process-contract.rb" "${rendered}"
ruby "${repo_root}/tests/katello-event-daemon-contract.rb" "${rendered_egress}"
ruby "${repo_root}/tests/foreman-shared-tmp-contract.rb" "${rendered}" true
ruby "${repo_root}/tests/foreman-shared-tmp-contract.rb" "${rendered_s3}" false
ruby "${repo_root}/tests/recovery-storage-contract.rb" "${rendered_backup}" true
ruby "${repo_root}/tests/recovery-storage-contract.rb" "${rendered_restore}" true
ruby "${repo_root}/tests/recovery-storage-contract.rb" "${rendered_s3_backup}" false
ruby "${repo_root}/tests/secret-rollout-contract.rb" "${rendered}" "${rendered_secret_rotation}"

ruby "${repo_root}/tests/kubernetes-invariants.rb" "${rendered_execution}"
ruby "${repo_root}/tests/kubernetes-invariants.rb" "${rendered_execution_egress}"
ruby "${repo_root}/tests/kubernetes-invariants.rb" "${rendered_execution_kind}"
ruby "${repo_root}/tests/kubernetes-invariants.rb" "${rendered_execution_secret_rotation}"
ruby "${repo_root}/tests/secret-rollout-contract.rb" \
  "${rendered_execution}" "${rendered_execution_secret_rotation}"
ruby -c "${execution_chart}/files/check-features.rb"

grep -q 'name: FOREMAN_PROXY_ENABLED_PLUGINS' "${rendered_execution}"
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
  --set ssh.hostKeyVerification.enabled=true >/dev/null 2>&1; then
  echo 'expected strict host-key checking without a trust Secret to be rejected' >&2
  exit 1
fi

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
shellcheck \
  "${repo_root}/scripts/upgrade-release.sh" \
  "${repo_root}/tests/upgrade-release.sh" \
  "${repo_root}/tests/kind/execution-plane.sh" \
  "${repo_root}/tests/kind/publish-ansible-content.sh" \
  "${repo_root}/tests/kind/run.sh"

ruby "${repo_root}/tests/plugin-compatibility.rb"
ruby "${repo_root}/tests/release-sets.rb"
ruby -c "${repo_root}/scripts/write-integration-evidence.rb"
ruby -c "${repo_root}/scripts/promote-release-set.rb"
ruby -c "${repo_root}/tests/integration-evidence.rb"
ruby -c "${repo_root}/tests/operator-contract.rb"
ruby "${repo_root}/tests/integration-evidence.rb"
"${repo_root}/tests/upgrade-release.sh"

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
grep -Fq 'assert_rollout_held' "${repo_root}/tests/kind/run.sh"
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
if [[ "$(grep -c 'startupProbe:' "${rendered}")" -ne 6 ]]; then
  echo 'expected startup probes for Foreman, Katello events, Candlepin, Pulp API/content, and the Pulp control proxy' >&2
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

if [[ "$(grep -c '^    - Egress$' "${rendered_egress}")" -ne 4 ]]; then
  echo 'expected component-scoped Foreman, Pulp, Candlepin, and control-proxy egress policies' >&2
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
  echo 'expected multiple Candlepin replicas without the HA contract to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
  --values "${repo_root}/tests/ha-values.yaml" \
  --set migrations.enabled=false >/dev/null 2>&1; then
  echo 'expected Candlepin HA without migration ownership to be rejected' >&2
  exit 1
fi

if helm template test "${chart}" \
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
  --values "${repo_root}/examples/pulp-s3-values.yaml" \
  --set maintenance.enabled=true \
  --set restore.enabled=true \
  --set restore.requestId=20260924-s3 \
  --set restore.confirmation=RESTORE >/dev/null 2>&1; then
  echo 'expected S3 restore without a coordinated bucket confirmation to be rejected' >&2
  exit 1
fi

helm template test "${chart}" \
  --values "${repo_root}/examples/pulp-s3-values.yaml" \
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
