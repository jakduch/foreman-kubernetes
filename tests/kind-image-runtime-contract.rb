#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'

root = File.expand_path('..', __dir__)
checker = File.read(File.join(root, 'tests/kind/image-runtime-contract.rb'))
harness = File.read(File.join(root, 'tests/kind/run.sh'))
workflow = File.read(File.join(root, '.github/workflows/integration.yaml'))
checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')

%w[foreman pulp-api candlepin foreman-proxy].each do |container|
  abort "runtime image contract omits #{container}" unless checker.include?("container: '#{container}'")
end
%w[FOREMAN_ENABLED_PLUGINS PULP_ENABLED_PLUGINS FOREMAN_PROXY_ENABLED_PLUGINS].each do |variable|
  abort "runtime image contract omits #{variable}" unless checker.include?(variable)
end
%w[runtimeImageId expectedImage packagedPlugins enabledPlugins versions].each do |field|
  abort "runtime image evidence omits #{field}" unless checker.include?("'#{field}'")
end
abort 'runtime image contract does not compare the kubelet image ID with the pinned digest' unless checker.include?('actual_image_id.include?("@#{digest}")')
abort 'runtime image contract does not reject root containers' unless checker.include?("actual_uid == '0'")
abort 'Kind harness does not execute the runtime image contract' unless harness.include?('tests/kind/image-runtime-contract.rb')
abort 'promotion evidence does not require the runtime image contract' unless checks.include?('pinned-image-runtime-contract')
abort 'CI does not retain the runtime image report' unless workflow.include?('artifacts/image-runtime-contract.json')

puts 'Full integration verifies exact image digests, identities, executables, and plugin inventories.'
