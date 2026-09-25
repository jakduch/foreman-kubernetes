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

candlepin_sql() {
  local statement="$1"

  kubectl --namespace "${namespace}" exec deployment/postgresql -- \
    env PGPASSWORD=candlepin-test \
    psql \
    --host=127.0.0.1 \
    --username=candlepin \
    --dbname=candlepin \
    --tuples-only \
    --no-align \
    --set=ON_ERROR_STOP=1 \
    --command="${statement}"
}

quartz_instances() {
  candlepin_sql \
    "SELECT instance_name FROM qrtz_scheduler_state WHERE sched_name = 'ForemanCandlepinKind' ORDER BY instance_name"
}

wait_for_quartz_instances() {
  local expected_count="$1"
  local actual_count
  local instances

  for _ in $(seq 1 120); do
    instances="$(quartz_instances)"
    actual_count="$(awk 'NF { count++ } END { print count + 0 }' <<<"${instances}")"
    if [[ "${actual_count}" == "${expected_count}" ]]; then
      printf '%s\n' "${instances}"
      return 0
    fi
    sleep 2
  done

  echo "Quartz has ${actual_count} registered instances, expected ${expected_count}" >&2
  return 1
}

latest_scheduled_job_id() {
  candlepin_sql \
    "SELECT id FROM cp_async_jobs WHERE job_key = 'ExpiredPoolsCleanupJob' ORDER BY created DESC LIMIT 1"
}

force_scheduled_job() {
  local updated

  updated="$(candlepin_sql \
    "WITH changed AS (UPDATE qrtz_triggers SET next_fire_time = (extract(epoch FROM clock_timestamp()) * 1000)::bigint, trigger_state = 'WAITING' WHERE sched_name = 'ForemanCandlepinKind' AND job_name = 'ExpiredPoolsCleanupJob' RETURNING 1) SELECT count(*) FROM changed")"
  if [[ "${updated}" != 1 ]]; then
    echo "Updated ${updated} Quartz triggers, expected 1" >&2
    exit 1
  fi
}

wait_for_new_scheduled_job() {
  local previous_id="$1"
  local job_id

  for _ in $(seq 1 90); do
    job_id="$(latest_scheduled_job_id)"
    if [[ -n "${job_id}" && "${job_id}" != "${previous_id}" ]]; then
      printf '%s\n' "${job_id}"
      return 0
    fi
    sleep 1
  done

  echo 'Quartz did not create a new ExpiredPoolsCleanupJob' >&2
  return 1
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

assert_quartz_trigger_failover() {
  local before_instances
  local after_instances
  local previous_job_id
  local first_scheduled_job
  local first_origin
  local second_scheduled_job

  previous_job_id="$(latest_scheduled_job_id)"
  force_scheduled_job
  first_scheduled_job="$(wait_for_job "$(wait_for_new_scheduled_job "${previous_job_id}")")"
  assert_single_delivery "${first_scheduled_job}" "scheduled job before Quartz failover"
  first_origin="$(jq --exit-status --raw-output '.origin' <<<"${first_scheduled_job}")"
  if ! candlepin_pod_names | grep --fixed-strings --line-regexp --quiet "${first_origin}"; then
    echo "Scheduled job origin ${first_origin} is not a running Candlepin Pod" >&2
    exit 1
  fi

  before_instances="$(quartz_instances)"
  kubectl --namespace "${namespace}" delete pod "${first_origin}" --wait=true --timeout=5m >/dev/null
  kubectl --namespace "${namespace}" rollout status \
    deployment/foreman-foreman-stack-candlepin --timeout=10m >/dev/null
  after_instances="$(wait_for_quartz_instances 2)"
  if [[ "${after_instances}" == "${before_instances}" ]]; then
    echo 'Quartz did not replace the terminated scheduler instance' >&2
    exit 1
  fi

  force_scheduled_job
  second_scheduled_job="$(wait_for_job "$(wait_for_new_scheduled_job \
    "$(jq --exit-status --raw-output '.id' <<<"${first_scheduled_job}")")")"
  assert_single_delivery "${second_scheduled_job}" "scheduled job after Quartz failover"
  if [[ "$(jq --exit-status --raw-output '.origin' <<<"${second_scheduled_job}")" == "${first_origin}" ]]; then
    echo 'The terminated Quartz scheduler created the post-failover job' >&2
    exit 1
  fi

  jq --null-input \
    --argjson first "${first_scheduled_job}" \
    --argjson second "${second_scheduled_job}" \
    '{first: $first, second: $second}'
}

assert_concurrent_request_service
scheduled_jobs="$(assert_quartz_trigger_failover)"

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
  --argjson scheduled_jobs "${scheduled_jobs}" \
  --arg candlepin_pod_uids "${candlepin_uids_after}" \
  --arg candlepin_pods "$(candlepin_pod_names)" \
  '{
    schemaVersion: 1,
    brokerRestarted: true,
    candlepinPodsRestarted: false,
    candlepinPodUids: ($candlepin_pod_uids | split("\n")),
    requestServicePods: ($candlepin_pods | split("\n")),
    jobs: [$first_job, $second_job],
    scheduledJobs: $scheduled_jobs
  }' >"${output_file}"

echo 'Candlepin delivered each async job once and reconnected after the Artemis restart.'
