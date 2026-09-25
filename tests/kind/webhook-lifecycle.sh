#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 seed|assert|cleanup TEMPORARY_DIRECTORY STATE_FILE" >&2
  exit 2
fi

mode="$1"
temporary_directory="$2"
state_file="$3"
namespace="${NAMESPACE:-foreman}"
receiver_name="webhook-receiver"
receiver_url="http://${receiver_name}:9999"

foreman_pod() {
  kubectl --namespace "${namespace}" get pod \
    --selector=app.kubernetes.io/component=foreman \
    --output=jsonpath='{.items[0].metadata.name}'
}

receiver_uid() {
  kubectl --namespace "${namespace}" get pod \
    --selector=app.kubernetes.io/name="${receiver_name}" \
    --output=jsonpath='{.items[0].metadata.uid}'
}

deploy_receiver() {
  local foreman_image

  foreman_image="$(kubectl --namespace "${namespace}" get \
    deployment/foreman-foreman-stack-foreman \
    --output=jsonpath='{.spec.template.spec.containers[0].image}')"
  kubectl --namespace "${namespace}" create configmap "${receiver_name}" \
    --from-file=receiver.rb="$(dirname "$0")/webhook-receiver.rb" \
    --dry-run=client --output=yaml | kubectl apply --filename=-
  kubectl apply --filename=- <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${receiver_name}
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: ${receiver_name}
    app.kubernetes.io/instance: webhook-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: ${receiver_name}
      app.kubernetes.io/instance: webhook-test
  template:
    metadata:
      labels:
        app.kubernetes.io/name: ${receiver_name}
        app.kubernetes.io/instance: webhook-test
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 994
        runAsGroup: 994
        fsGroup: 994
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: receiver
          image: ${foreman_image}
          imagePullPolicy: IfNotPresent
          command: [ruby, /opt/webhook-receiver/receiver.rb]
          ports:
            - name: http
              containerPort: 9999
          readinessProbe:
            tcpSocket:
              port: http
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: receiver
              mountPath: /opt/webhook-receiver
              readOnly: true
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: receiver
          configMap:
            name: ${receiver_name}
        - name: tmp
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: ${receiver_name}
  namespace: ${namespace}
spec:
  selector:
    app.kubernetes.io/name: ${receiver_name}
    app.kubernetes.io/instance: webhook-test
  ports:
    - name: http
      port: 9999
      targetPort: http
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${receiver_name}-ingress
  namespace: ${namespace}
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: ${receiver_name}
      app.kubernetes.io/instance: webhook-test
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchExpressions:
              - key: app.kubernetes.io/instance
                operator: In
                values: [foreman]
              - key: app.kubernetes.io/component
                operator: In
                values: [foreman, dynflow-worker]
      ports:
        - protocol: TCP
          port: 9999
EOF
  kubectl --namespace "${namespace}" rollout status \
    deployment/"${receiver_name}" --timeout=5m
}

wait_for_delivery() {
  local marker="$1"

  for _ in $(seq 1 120); do
    if kubectl --namespace "${namespace}" logs deployment/"${receiver_name}" \
      --all-containers=true 2>/dev/null | grep --fixed-strings --quiet "${marker}"; then
      return
    fi
    sleep 2
  done

  echo "webhook receiver did not observe ${marker}" >&2
  kubectl --namespace "${namespace}" logs deployment/"${receiver_name}" \
    --all-containers=true >&2 || true
  exit 1
}

rails_runner() {
  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- "$@"
}

seed_lifecycle() {
  local identifier
  local template_name
  local webhook_name
  local first_domain
  local second_domain
  local receiver_uid_before

  identifier="$(date -u +%Y%m%d%H%M%S)-${RANDOM}"
  template_name="Kubernetes webhook template ${identifier}"
  webhook_name="Kubernetes webhook ${identifier}"
  first_domain="webhook-${identifier}.example.test"
  second_domain="webhook-restarted-${identifier}.example.test"
  jq --null-input \
    --arg templateName "${template_name}" \
    --arg webhookName "${webhook_name}" \
    --arg firstDomain "${first_domain}" \
    --arg secondDomain "${second_domain}" \
    '{templateName: $templateName, webhookName: $webhookName, firstDomain: $firstDomain, secondDomain: $secondDomain}' \
    > "${state_file}"

  deploy_receiver
  rails_runner env \
    "TEMPLATE_NAME=${template_name}" \
    "WEBHOOK_NAME=${webhook_name}" \
    "DOMAIN_NAME=${first_domain}" \
    "RECEIVER_URL=${receiver_url}" \
    bin/rails runner '
      Webhook.unscoped.where(name: ENV.fetch("WEBHOOK_NAME")).destroy_all
      WebhookTemplate.unscoped.where(name: ENV.fetch("TEMPLATE_NAME")).destroy_all
      Domain.unscoped.where(name: ENV.fetch("DOMAIN_NAME")).destroy_all
      template = WebhookTemplate.create!(
        name: ENV.fetch("TEMPLATE_NAME"),
        template: %q({"id": <%= @object.id %>, "name": "<%= @object.name %>"})
      )
      Webhook.create!(
        name: ENV.fetch("WEBHOOK_NAME"),
        target_url: "#{ENV.fetch("RECEIVER_URL")}/success",
        http_method: "POST",
        http_content_type: "application/json",
        event: "domain_created.event.foreman",
        webhook_template: template,
        enabled: true,
        verify_ssl: false
      )
      Domain.create!(name: ENV.fetch("DOMAIN_NAME"))
    '
  wait_for_delivery "${first_domain}"

  rails_runner env \
    "WEBHOOK_NAME=${webhook_name}" \
    "RECEIVER_URL=${receiver_url}" \
    bin/rails runner '
      webhook = Webhook.unscoped.find_by!(name: ENV.fetch("WEBHOOK_NAME"))
      webhook.update!(target_url: "#{ENV.fetch("RECEIVER_URL")}/failure")
      result = webhook.test(payload: {probe: "expected-failure"})
      abort "Expected HTTP 503, got #{result.inspect}" unless result[:status] == :error && result[:http_status] == 503
      webhook.update!(target_url: "#{ENV.fetch("RECEIVER_URL")}/success")
      result = webhook.test(payload: {probe: "corrected-destination"})
      abort "Corrected destination failed: #{result.inspect}" unless result[:status] == :success && result[:http_status] == 204
    '

  receiver_uid_before="$(receiver_uid)"
  kubectl --namespace "${namespace}" delete pod \
    --selector=app.kubernetes.io/name="${receiver_name}" --wait=true
  kubectl --namespace "${namespace}" rollout status \
    deployment/"${receiver_name}" --timeout=5m
  if [[ "$(receiver_uid)" == "${receiver_uid_before}" ]]; then
    echo 'webhook receiver Pod was not replaced' >&2
    exit 1
  fi

  rails_runner env \
    "DOMAIN_NAME=${second_domain}" \
    bin/rails runner 'Domain.create!(name: ENV.fetch("DOMAIN_NAME"))'
  wait_for_delivery "${second_domain}"
}

assert_recovered_lifecycle() {
  local template_name
  local webhook_name
  local first_domain
  local second_domain
  local recovery_domain

  deploy_receiver
  template_name="$(jq --exit-status --raw-output '.templateName' "${state_file}")"
  webhook_name="$(jq --exit-status --raw-output '.webhookName' "${state_file}")"
  first_domain="$(jq --exit-status --raw-output '.firstDomain' "${state_file}")"
  second_domain="$(jq --exit-status --raw-output '.secondDomain' "${state_file}")"
  recovery_domain="recovered-${second_domain}"

  rails_runner env \
    "TEMPLATE_NAME=${template_name}" \
    "WEBHOOK_NAME=${webhook_name}" \
    "DOMAIN_NAME=${recovery_domain}" \
    bin/rails runner '
      WebhookTemplate.unscoped.find_by!(name: ENV.fetch("TEMPLATE_NAME"))
      Webhook.unscoped.find_by!(name: ENV.fetch("WEBHOOK_NAME"))
      Domain.create!(name: ENV.fetch("DOMAIN_NAME"))
    '
  wait_for_delivery "${recovery_domain}"

  rails_runner env \
    "TEMPLATE_NAME=${template_name}" \
    "WEBHOOK_NAME=${webhook_name}" \
    "FIRST_DOMAIN=${first_domain}" \
    "SECOND_DOMAIN=${second_domain}" \
    "RECOVERY_DOMAIN=${recovery_domain}" \
    bin/rails runner '
      Webhook.unscoped.find_by!(name: ENV.fetch("WEBHOOK_NAME")).destroy!
      WebhookTemplate.unscoped.find_by!(name: ENV.fetch("TEMPLATE_NAME")).destroy!
      Domain.unscoped.where(name: [ENV.fetch("FIRST_DOMAIN"), ENV.fetch("SECOND_DOMAIN"), ENV.fetch("RECOVERY_DOMAIN")]).destroy_all
    '
  cleanup_receiver
}

cleanup_receiver() {
  kubectl --namespace "${namespace}" delete \
    deployment/"${receiver_name}" \
    service/"${receiver_name}" \
    configmap/"${receiver_name}" \
    networkpolicy/"${receiver_name}-ingress" \
    --ignore-not-found=true
}

case "${mode}" in
  seed)
    seed_lifecycle
    ;;
  assert)
    assert_recovered_lifecycle
    ;;
  cleanup)
    cleanup_receiver
    ;;
  *)
    echo "unsupported mode: ${mode}" >&2
    exit 2
    ;;
esac
