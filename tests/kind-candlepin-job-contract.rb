#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

root = File.expand_path('..', __dir__)
drill = File.read(File.join(root, 'tests/kind/candlepin-job-delivery.sh'))
harness = File.read(File.join(root, 'tests/kind/run.sh'))
workflow = File.read(File.join(root, '.github/workflows/integration.yaml'))
checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')

abort 'Candlepin drill does not queue a real heal job' unless drill.include?('/entitlements')
abort 'Candlepin drill does not use the Katello OAuth client path' unless drill.include?('CandlepinResource')
abort 'Candlepin drill does not require a successful terminal job' unless drill.include?('!= FINISHED')
abort 'Candlepin drill does not reject redelivery' unless drill.include?("!= 1")
abort 'Candlepin drill does not stop the broker' unless drill.include?('deployment/artemis --replicas=0')
abort 'Candlepin drill does not restart the broker' unless drill.include?('deployment/artemis --replicas=1')
abort 'Candlepin drill does not prove in-process reconnect' unless drill.include?('Candlepin Pods restarted instead of reconnecting')
abort 'Kind harness does not execute the Candlepin job drill' unless harness.include?('tests/kind/candlepin-job-delivery.sh')
abort 'promotion evidence does not require the Candlepin job drill' unless checks.include?('candlepin-artemis-delivery-reconnect')
abort 'CI does not retain the Candlepin job report' unless workflow.include?('artifacts/candlepin-job-delivery.json')

puts 'Candlepin integration covers one-time Artemis delivery and in-process broker reconnect.'
