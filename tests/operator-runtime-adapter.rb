#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'yaml'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/runtime_adapter').to_s

class RecordingHelmRunner
  attr_reader :calls, :renders, :values_modes

  def initialize
    @real = ForemanRelease::CommandRunner.new
    @calls = []
    @renders = {}
    @values_modes = []
  end

  def run(*command, stdin_data: '')
    @calls << [command, stdin_data]
    if command.first == 'helm'
      command.each_index do |index|
        next unless command[index] == '--values'

        candidate = command[index + 1]
        @values_modes << (File.stat(candidate).mode & 0o777) if candidate.include?('foreman-release-values-')
      end
    end
    case command.first(2)
    when %w[helm upgrade]
      'submitted'
    when %w[helm status]
      JSON.generate('version' => command.include?('execution') ? 4 : 2)
    when %w[helm template]
      output = @real.run(*command, stdin_data: stdin_data)
      @renders[command.fetch(2)] = YAML.load_stream(output).compact
      output
    else
      @real.run(*command, stdin_data: stdin_data)
    end
  end
end

class RuntimeKubernetesClient
  attr_reader :created
  attr_accessor :application_values, :execution_values

  def initialize(application_values:, execution_values:)
    @application_values = application_values
    @execution_values = execution_values
    @resources = Hash.new { |hash, key| hash[key] = [] }
    @created = []
  end

  def secret_value(_namespace, name, _key)
    return @application_values if name == 'application-values'
    return @execution_values if name == 'execution-values'

    raise KeyError, "unknown Secret #{name}"
  end

  def resources(_namespace, type, labels: {})
    @resources[type].select do |resource|
      actual = resource.dig('metadata', 'labels') || {}
      labels.all? { |key, value| actual[key] == value }
    end
  end

  def create(_namespace, resource)
    copy = Marshal.load(Marshal.dump(resource))
    @resources['jobs'] << copy
    @created << copy
    copy
  end

  def replace(type, resources)
    @resources[type] = Marshal.load(Marshal.dump(resources))
  end
end

class RuntimeLeaseManager
  def acquire(_resource, _operation)
    ForemanRelease::Observation.new(state: :succeeded)
  end

  alias renew acquire

  def release(_resource, _operation)
    true
  end
end

def complete_job(job)
  copy = Marshal.load(Marshal.dump(job))
  copy['status'] = {'conditions' => [{'type' => 'Complete', 'status' => 'True'}]}
  copy
end

def available_deployment(deployment)
  copy = Marshal.load(Marshal.dump(deployment))
  copy['metadata']['generation'] = 1
  copy['status'] = {
    'observedGeneration' => 1,
    'availableReplicas' => copy.dig('spec', 'replicas') || 1,
    'conditions' => [
      {'type' => 'Progressing', 'status' => 'True'},
      {'type' => 'Available', 'status' => 'True'}
    ]
  }
  copy
end

runner = RecordingHelmRunner.new
kubernetes = RuntimeKubernetesClient.new(
  application_values: root.join('examples/cluster-values.yaml').read,
  execution_values: root.join('examples/execution-proxy-values.yaml').read
)
adapter = ForemanRelease::RuntimeAdapter.new(
  root: root,
  runner: runner,
  kubernetes_client: kubernetes,
  lease_manager: RuntimeLeaseManager.new
)
resource = {
  'apiVersion' => 'platform.theforeman.org/v1alpha1',
  'kind' => 'ForemanRelease',
  'metadata' => {
    'name' => 'foreman',
    'namespace' => 'platform',
    'uid' => '12345678-1234-1234-1234-123456789abc'
  },
  'spec' => {
    'compatibilitySet' => 'nightly-candidate-2026-09-24',
    'allowCandidate' => true,
    'application' => {
      'releaseName' => 'foreman',
      'valuesSecretRef' => {'name' => 'application-values', 'key' => 'values.yaml'}
    },
    'executionProxy' => {
      'releaseName' => 'execution',
      'valuesSecretRef' => {'name' => 'execution-values', 'key' => 'values.yaml'}
    }
  }
}
operation = {'id' => '12345678-1234-1234-1234-123456789abc-g7'}

validation = adapter.validate(resource, operation)
raise 'release validation failed' unless validation.state == :succeeded
raise 'validation did not pin all four release inputs' unless validation.details.keys.sort == ForemanRelease::RuntimeAdapter::INPUT_DIGESTS.keys.sort
operation.merge!(validation.details)
raise 'Secret values were not written with mode 0600' unless runner.values_modes.all? { |mode| mode == 0o600 }

original_values = kubernetes.application_values
kubernetes.application_values = "#{original_values}\n# changed during release\n"
begin
  adapter.ensure_migrations(resource, operation)
  raise 'changed values Secret was accepted during an operation'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('changed during operation')
ensure
  kubernetes.application_values = original_values
end

first_migration = adapter.ensure_migrations(resource, operation)
raise 'initial migration reconciliation did not remain pending' unless first_migration.state == :pending
upgrade = runner.calls.map(&:first).find { |command| command.first(2) == %w[helm upgrade] && command.include?('foreman') }
raise 'application Helm release was not submitted' unless upgrade
raise 'runtime adapter used blocking Helm wait' if upgrade.any? { |argument| argument.start_with?('--wait') }
raise 'application operation ID was not passed to Helm' unless upgrade.include?("releaseOperation.id=#{operation.fetch('id')}")

application_render = runner.renders.fetch('foreman')
operation_jobs = application_render.select do |item|
  item['kind'] == 'Job' && %w[candlepin-migrate pulp-migrate foreman-migrate pulp-registration].include?(item.dig('metadata', 'labels', 'app.kubernetes.io/component'))
end
kubernetes.replace('jobs', operation_jobs.map { |job| complete_job(job) })
migrations = adapter.ensure_migrations(resource, operation)
raise 'completed migrations were not adopted' unless migrations.state == :succeeded
raise 'migration Job names were not recorded' unless migrations.details.fetch(:migrationJobs).length == 3

deployments = application_render.select { |item| item['kind'] == 'Deployment' }.map { |item| available_deployment(item) }
kubernetes.replace('deployments', deployments)
application = adapter.ensure_application(resource, operation)
raise "available application was not accepted: #{application.message}" unless application.state == :succeeded
raise 'application Helm revision was not recorded' unless application.details == {applicationRevision: 2}

application_smoke = adapter.ensure_application_smoke(resource, operation)
raise 'application smoke Job was not submitted asynchronously' unless application_smoke.state == :pending
smoke = kubernetes.created.last
raise 'smoke Job retained a Helm hook annotation' if smoke.dig('metadata', 'annotations').keys.any? { |key| key.start_with?('helm.sh/hook') }
raise 'smoke Job is not owned by the ForemanRelease' unless smoke.dig('metadata', 'ownerReferences', 0, 'uid') == resource.dig('metadata', 'uid')
kubernetes.replace('jobs', kubernetes.resources('platform', 'jobs').map { |job| complete_job(job) })
raise 'completed application smoke Job was not adopted' unless adapter.ensure_application_smoke(resource, operation).state == :succeeded

proxy_submission = adapter.ensure_proxy(resource, operation)
raise 'initial execution proxy reconciliation did not remain pending' unless proxy_submission.state == :pending
proxy_upgrade = runner.calls.map(&:first).find { |command| command.first(2) == %w[helm upgrade] && command.include?('execution') }
raise 'execution proxy Helm release was not submitted' unless proxy_upgrade
raise 'execution operation ID was not passed to Helm' unless proxy_upgrade.include?("releaseOperation.id=#{operation.fetch('id')}")

execution_render = runner.renders.fetch('execution')
kubernetes.replace(
  'deployments',
  deployments + execution_render.select { |item| item['kind'] == 'Deployment' }.map { |item| available_deployment(item) }
)
proxy = adapter.ensure_proxy(resource, operation)
raise "available execution proxy was not accepted: #{proxy.message}" unless proxy.state == :succeeded
raise 'execution proxy Helm revision was not recorded' unless proxy.details == {executionProxyRevision: 4}

final_smoke = adapter.ensure_final_smoke(resource, operation)
raise 'final smoke Job was not submitted asynchronously' unless final_smoke.state == :pending
raise 'application and final smoke Jobs reused a name' unless kubernetes.created.map { |job| job.dig('metadata', 'name') }.uniq.length == 2

puts 'Runtime adapter pins inputs, submits once, and adopts release Jobs and Deployments.'
