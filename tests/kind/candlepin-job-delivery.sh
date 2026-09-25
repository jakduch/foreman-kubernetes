#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 OUTPUT" >&2
  exit 2
fi

output_file="$1"
namespace="${NAMESPACE:-foreman}"
owner_label="Kubernetes_Integration"
candlepin_service="foreman-foreman-stack-candlepin"
candlepin_port="24443"

foreman_pod() {
  kubectl --namespace "${namespace}" get pod \
    --selector=app.kubernetes.io/component=foreman \
    --output=jsonpath='{.items[0].metadata.name}'
}

candlepin_pod_names() {
  kubectl --namespace "${namespace}" get pods \
    --selector=app.kubernetes.io/component=candlepin \
    --output=json | jq --raw-output \
      '.items[] | select(.status.phase == "Running") | .metadata.name' | sort
}

candlepin_pod_uids() {
  kubectl --namespace "${namespace}" get pods \
    --selector=app.kubernetes.io/component=candlepin \
    --output=json | jq --raw-output '.items[].metadata.uid' | sort
}

candlepin_pods_with_ips() {
  kubectl --namespace "${namespace}" get pods \
    --selector=app.kubernetes.io/component=candlepin \
    --output=json | jq --raw-output \
      '.items[] | select(.status.phase == "Running") | [.metadata.name, .status.podIP] | @tsv' | sort
}

probe_candlepin_pod() {
  local pod_name="$1"
  local pod_ip="$2"

  kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    env \
      "CANDLEPIN_POD_NAME=${pod_name}" \
      "CANDLEPIN_POD_IP=${pod_ip}" \
      "CANDLEPIN_SERVICE_NAME=${candlepin_service}" \
      "CANDLEPIN_SERVICE_PORT=${candlepin_port}" \
      CANDLEPIN_REQUEST_COUNT=4 \
    bin/rails runner '
      require "json"
      require "openssl"
      require "socket"

      host = ENV.fetch("CANDLEPIN_SERVICE_NAME")
      store = OpenSSL::X509::Store.new
      store.add_file("/etc/foreman/katello-default-ca.crt")
      requests = Integer(ENV.fetch("CANDLEPIN_REQUEST_COUNT")).times.map do
        Thread.new do
          socket = TCPSocket.new(ENV.fetch("CANDLEPIN_POD_IP"), Integer(ENV.fetch("CANDLEPIN_SERVICE_PORT")))
          context = OpenSSL::SSL::SSLContext.new
          context.cert_store = store
          context.verify_mode = OpenSSL::SSL::VERIFY_PEER
          tls = OpenSSL::SSL::SSLSocket.new(socket, context)
          tls.hostname = host
          tls.connect
          tls.post_connection_check(host)
          tls.write("GET /candlepin/status HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n")
          response = tls.read
          status, body = response.split("\r\n\r\n", 2)
          abort "Candlepin request failed: #{status}" unless status&.start_with?("HTTP/1.1 200")
          abort "Candlepin is not in NORMAL mode: #{body}" unless body&.match?(/"mode"\s*:\s*"NORMAL"/)
        ensure
          tls&.close
          socket&.close
        end
      end
      requests.each(&:value)
      puts "CANDLEPIN_POD_READY=#{ENV.fetch("CANDLEPIN_POD_NAME")}"
    '
}

assert_concurrent_request_service() {
  local pod_count=0
  local pod_name
  local pod_ip
  local pid
  local -a pids=()

  while IFS=$'\t' read -r pod_name pod_ip; do
    [[ -n "${pod_name}" && -n "${pod_ip}" ]] || continue
    pod_count=$((pod_count + 1))
    probe_candlepin_pod "${pod_name}" "${pod_ip}" >/dev/null &
    pids+=("$!")
  done < <(candlepin_pods_with_ips)

  if [[ "${pod_count}" -ne 2 ]]; then
    echo "Candlepin has ${pod_count} running request pods, expected 2" >&2
    exit 1
  fi
  for pid in "${pids[@]}"; do
    wait "${pid}"
  done
}

start_job() {
  local output
  local job

  output="$(kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    env "CANDLEPIN_OWNER_LABEL=${owner_label}" bin/rails runner '
      User.current = User.unscoped.find_by!(login: "admin")
      resource = Katello::Resources::Candlepin::CandlepinResource
      path = "/candlepin/owners/#{ENV.fetch("CANDLEPIN_OWNER_LABEL")}/entitlements"
      response = resource.post(path, "{}", resource.default_headers)
      puts "CANDLEPIN_JOB=#{response.body}"
    ')"
  job="$(sed -n 's/^CANDLEPIN_JOB=//p' <<<"${output}" | tail -n 1)"
  jq --exit-status '.id and .state' <<<"${job}" >/dev/null
  printf '%s\n' "${job}"
}

wait_for_job() {
  local job_id="$1"
  local output
  local job

  output="$(kubectl --namespace "${namespace}" exec "$(foreman_pod)" -- \
    env "CANDLEPIN_JOB_ID=${job_id}" bin/rails runner '
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 300
      loop do
        job = Katello::Resources::Candlepin::Job.get(ENV.fetch("CANDLEPIN_JOB_ID"))
        unless Katello::Resources::Candlepin::Job.not_finished?(job)
          puts "CANDLEPIN_JOB=#{JSON.generate(job)}"
          break
        end
        abort "Timed out waiting for Candlepin job #{job[:id]}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 1
      end
    ')"
  job="$(sed -n 's/^CANDLEPIN_JOB=//p' <<<"${output}" | tail -n 1)"
  jq --exit-status '.id and .state' <<<"${job}" >/dev/null
  printf '%s\n' "${job}"
}

assert_single_delivery() {
  local job="$1"
  local description="$2"
  local executor

  if [[ "$(jq --raw-output '.state' <<<"${job}")" != FINISHED ]]; then
    echo "${description} did not finish successfully: ${job}" >&2
    exit 1
  fi
  if [[ "$(jq --raw-output '.attempts' <<<"${job}")" != 1 ]]; then
    echo "${description} was delivered more than once: ${job}" >&2
    exit 1
  fi
  executor="$(jq --exit-status --raw-output '.executor' <<<"${job}")"
  if ! candlepin_pod_names | grep --fixed-strings --line-regexp --quiet "${executor}"; then
    echo "${description} executor ${executor} is not a running Candlepin Pod" >&2
    exit 1
  fi
}

assert_concurrent_request_service

first_job="$(start_job)"
first_job="$(wait_for_job "$(jq --exit-status --raw-output '.id' <<<"${first_job}")")"
assert_single_delivery "${first_job}" "job before broker restart"

candlepin_uids_before="$(candlepin_pod_uids)"
kubectl --namespace "${namespace}" scale deployment/artemis --replicas=0
kubectl --namespace "${namespace}" rollout status deployment/artemis --timeout=5m
if [[ "$(kubectl --namespace "${namespace}" get deployment/artemis \
  --output=json | jq '.status.replicas // 0')" != 0 ]]; then
  echo 'Artemis did not stop completely' >&2
  exit 1
fi

kubectl --namespace "${namespace}" scale deployment/artemis --replicas=1
kubectl --namespace "${namespace}" rollout status deployment/artemis --timeout=5m
kubectl --namespace "${namespace}" wait \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=candlepin \
  --timeout=5m

candlepin_uids_after="$(candlepin_pod_uids)"
if [[ "${candlepin_uids_after}" != "${candlepin_uids_before}" ]]; then
  echo 'Candlepin Pods restarted instead of reconnecting to Artemis' >&2
  exit 1
fi

second_job=""
for _ in $(seq 1 60); do
  if second_job="$(start_job 2>/dev/null)"; then
    break
  fi
  sleep 2
done
if [[ -z "${second_job}" ]]; then
  echo 'Candlepin did not reconnect to Artemis after the broker restart' >&2
  exit 1
fi
second_job="$(wait_for_job "$(jq --exit-status --raw-output '.id' <<<"${second_job}")")"
assert_single_delivery "${second_job}" "job after broker restart"

mkdir -p "$(dirname "${output_file}")"
jq --null-input \
  --argjson first_job "${first_job}" \
  --argjson second_job "${second_job}" \
  --arg candlepin_pod_uids "${candlepin_uids_after}" \
  --arg candlepin_pods "$(candlepin_pod_names)" \
  '{
    schemaVersion: 1,
    brokerRestarted: true,
    candlepinPodsRestarted: false,
    candlepinPodUids: ($candlepin_pod_uids | split("\n")),
    requestServicePods: ($candlepin_pods | split("\n")),
    jobs: [$first_job, $second_job]
  }' >"${output_file}"

echo 'Candlepin delivered each async job once and reconnected after the Artemis restart.'
