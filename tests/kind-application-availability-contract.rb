#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

root = File.expand_path('..', __dir__)
drill = File.read(File.join(root, 'tests/kind/application-availability.sh'))
harness = File.read(File.join(root, 'tests/kind/run.sh'))
checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')

required = {
  'scale Foreman web to two replicas' => 'scale deployment/"${deployment}" --replicas=2',
  'require two ready Pods' => 'wait_for_ready_count 2',
  'send concurrent requests' => 'probe_worker "${worker}" &',
  'verify Foreman and Katello health' => '.results.foreman.database.active == true and .results.katello.status == "ok"',
  'replace one web Pod' => 'delete pod "${pod_to_delete}"',
  'reject any failed request' => 'Foreman returned an invalid response',
  'restore the declared replica count' => 'scale deployment/"${deployment}" --replicas=1'
}
required.each do |description, contract|
  abort "application availability drill does not #{description}" unless drill.include?(contract)
end

unless harness.include?('tests/kind/application-availability.sh')
  abort 'Kind harness does not execute the application availability drill'
end
unless checks.include?('foreman-web-request-continuity')
  abort 'promotion evidence does not require Foreman request continuity'
end

puts 'Foreman web integration requires healthy concurrent requests through one Pod replacement.'
