#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'json'
require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/kubernetes_client').to_s

class FakeRunner
  attr_reader :calls

  def initialize(*responses)
    @responses = responses
    @calls = []
  end

  def run(*command, stdin_data: '')
    @calls << [command, stdin_data]
    raise 'unexpected command' if @responses.empty?

    @responses.shift
  end
end

secret_payload = 'database: secret-value'
runner = FakeRunner.new(
  JSON.generate('items' => [{'metadata' => {'name' => 'foreman'}}]),
  JSON.generate('data' => {'values.yaml' => Base64.strict_encode64(secret_payload)}),
  JSON.generate('metadata' => {'name' => 'foreman'}, 'status' => {'phase' => 'Preflight'})
)
client = ForemanRelease::KubernetesClient.new(runner: runner)

releases = client.releases('platform')
raise 'release list was not decoded' unless releases.dig(0, 'metadata', 'name') == 'foreman'
raise 'values Secret was not decoded' unless client.secret_value('platform', 'foreman-values', 'values.yaml') == secret_payload

resource = {
  'metadata' => {
    'namespace' => 'platform',
    'name' => 'foreman',
    'resourceVersion' => '42'
  }
}
status = {'phase' => 'Preflight', 'observedGeneration' => 3}
client.write_status(resource, status)
patch_command = runner.calls.last.first
patch = JSON.parse(patch_command.fetch(patch_command.index('--patch') + 1))
raise 'status update does not guard resourceVersion' unless patch.first == {
  'op' => 'test', 'path' => '/metadata/resourceVersion', 'value' => '42'
}
raise 'status update does not use the status subresource' unless patch_command.include?('--subresource=status')
raise 'status update contains Secret material' if patch_command.join(' ').include?('secret-value')
raise 'kubectl commands unexpectedly use a shell' unless runner.calls.all? { |call| call.first.first == 'kubectl' }

missing_key = ForemanRelease::KubernetesClient.new(
  runner: FakeRunner.new(JSON.generate('data' => {}))
)
begin
  missing_key.secret_value('platform', 'foreman-values', 'missing')
  raise 'missing Secret key was accepted'
rescue KeyError
  nil
end

resource_runner = FakeRunner.new(
  JSON.generate('items' => [{'metadata' => {'name' => 'migration'}}]),
  JSON.generate('metadata' => {'name' => 'migration'}),
  JSON.generate('metadata' => {'name' => 'smoke'})
)
resource_client = ForemanRelease::KubernetesClient.new(runner: resource_runner)
listed = resource_client.resources('platform', 'jobs', labels: {'operation' => 'release-1', 'owner' => 'uid-1'})
raise 'generic resource list was not decoded' unless listed.dig(0, 'metadata', 'name') == 'migration'
selector_command = resource_runner.calls.first.first
selector = selector_command.fetch(selector_command.index('--selector') + 1)
raise 'resource labels are not deterministic' unless selector == 'operation=release-1,owner=uid-1'
raise 'single resource was not decoded' unless resource_client.resource('platform', 'job', 'migration').dig('metadata', 'name') == 'migration'
created = resource_client.create('platform', {'apiVersion' => 'batch/v1', 'kind' => 'Job', 'metadata' => {'name' => 'smoke'}})
raise 'created resource was not decoded' unless created.dig('metadata', 'name') == 'smoke'
raise 'resource create did not use stdin' unless resource_runner.calls.last.last.include?('"kind":"Job"')

puts 'Kubernetes client protects status concurrency and keeps values in same-namespace Secrets.'
