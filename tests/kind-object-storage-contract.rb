#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'

root = File.expand_path('..', __dir__)
resources = YAML.load_stream(File.read(File.join(root, 'tests/kind/object-storage.yaml'))).compact
drill = File.read(File.join(root, 'tests/kind/object-storage.sh'))
harness = File.read(File.join(root, 'tests/kind/run.sh'))
workflow = File.read(File.join(root, '.github/workflows/integration.yaml'))
checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')

deployment = resources.find { |resource| resource['kind'] == 'Deployment' }
abort 'object-storage fixture has no Deployment' unless deployment
image = deployment.dig('spec', 'template', 'spec', 'containers', 0, 'image')
abort 'object-storage fixture image is not digest-pinned' unless image&.match?(/seaweedfs:4\.47@sha256:[0-9a-f]{64}\z/)
args = deployment.dig('spec', 'template', 'spec', 'containers', 0, 'args')
abort 'object-storage fixture does not expose the S3 API' unless args.include?('-s3.port=8333')

required = {
  'render the chart-owned S3 test' => '--show-only templates/tests/pulp-object-storage.yaml',
  'use a dedicated key prefix' => 'pulp.storage.s3.location=qualification',
  'exercise path-style addressing' => 'pulp.storage.s3.addressingStyle=path',
  'wait for a successful probe Job' => '--for=condition=complete',
  'verify a multipart payload' => '.bytes == 9437185',
  'verify version history' => '.objectVersions >= 1',
  'retain qualification evidence' => 'pulp-object-storage.json'
}
required.each do |description, contract|
  abort "object-storage drill does not #{description}" unless drill.include?(contract)
end

abort 'Kind harness does not execute the object-storage drill' unless harness.include?('tests/kind/object-storage.sh')
abort 'CI does not retain the object-storage report' unless workflow.include?('artifacts/pulp-object-storage.json')
abort 'promotion evidence does not require the S3 round trip' unless checks.include?('pulp-s3-versioned-multipart-round-trip')

puts 'Kind integration qualifies Pulp against a versioned S3-compatible endpoint.'
