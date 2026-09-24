#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'yaml'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/runtime_adapter').to_s

class RecordingHelmRunner
  attr_reader :calls, :renders, :values_modes
  attr_accessor :existing_releases

  def initialize
    @real = ForemanRelease::CommandRunner.new
    @calls = []
    @renders = {}
    @values_modes = []
    @existing_releases = []
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
    when %w[helm list]
      JSON.generate(@existing_releases.map { |name| {'name' => name} })
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
  attr_reader :created, :created_resources, :deleted
  attr_accessor :application_values, :execution_values, :releases_list

  def initialize(application_values:, execution_values:)
    @application_values = application_values
    @execution_values = execution_values
    @resources = Hash.new { |hash, key| hash[key] = [] }
    @created = []
    @created_resources = []
    @deleted = []
    @releases_list = []
  end

  def releases(_namespace)
    @releases_list
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
    type = resource_type(copy.fetch('kind'))
    if @resources[type].any? { |item| item.dig('metadata', 'name') == copy.dig('metadata', 'name') }
      raise ForemanRelease::CommandError.new(['kubectl', 'create'], 'AlreadyExists', 1)
    end

    copy['metadata']['resourceVersion'] ||= (@created_resources.length + 1).to_s
    @resources[type] << copy
    @created_resources << copy
    @created << copy if type == 'jobs'
    copy
  end

  def replace(type_or_namespace, resources_or_resource)
    if resources_or_resource.is_a?(Array)
      @resources[type_or_namespace] = Marshal.load(Marshal.dump(resources_or_resource))
      return resources_or_resource
    end

    resource = Marshal.load(Marshal.dump(resources_or_resource))
    type = resource_type(resource.fetch('kind'))
    index = @resources[type].index { |item| item.dig('metadata', 'name') == resource.dig('metadata', 'name') }
    raise 'replaced resource does not exist' unless index

    resource['metadata']['resourceVersion'] = (Integer(resource.dig('metadata', 'resourceVersion')) + 1).to_s
    @resources[type][index] = resource
    resource
  end

  def resource(_namespace, type, name)
    plural = type.end_with?('s') ? type : "#{type}s"
    @resources[plural].find { |item| item.dig('metadata', 'name') == name } || raise('resource not found')
  end

  def delete(_namespace, type, name)
    plural = type.end_with?('s') ? type : "#{type}s"
    @resources[plural].reject! { |item| item.dig('metadata', 'name') == name }
    @deleted << [plural, name]
    true
  end

  private

  def resource_type(kind)
    {
      'ConfigMap' => 'configmaps',
      'Job' => 'jobs',
      'PersistentVolumeClaim' => 'persistentvolumeclaims',
      'ServiceAccount' => 'serviceaccounts'
    }.fetch(kind)
  end
end

class RuntimeLeaseManager
  attr_reader :calls

  def initialize
    @calls = []
  end

  def acquire(_resource, operation)
    @calls << [:acquire, operation.fetch('id')]
    ForemanRelease::Observation.new(state: :succeeded)
  end

  def release(_resource, operation)
    @calls << [:release, operation.fetch('id')]
    true
  end
end

class RuntimePreflight
  attr_reader :calls

  def initialize
    @calls = []
  end

  def validate!(documents, namespace)
    @calls << [documents, namespace]
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
preflight = RuntimePreflight.new
kubernetes = RuntimeKubernetesClient.new(
  application_values: root.join('examples/cluster-values.yaml').read,
  execution_values: root.join('examples/execution-proxy-values.yaml').read
)
runtime_lease = RuntimeLeaseManager.new
adapter = ForemanRelease::RuntimeAdapter.new(
  root: root,
  lease_identity: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
  runner: runner,
  kubernetes_client: kubernetes,
  lease_manager: runtime_lease,
  preflight: preflight
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
kubernetes.releases_list = [resource]

lease_holder = "#{operation.fetch('id')}:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
raise 'controller did not acquire its uniquely fenced operation Lease' unless adapter.acquire_lease(resource, operation).state == :succeeded
raise 'controller did not renew through a race-safe acquire' unless adapter.renew_lease(resource, operation).state == :succeeded
raise 'controller did not release its fenced operation Lease' unless adapter.release_lease(resource, operation)
raise 'durable operation ID was used as a shared holder identity' unless runtime_lease.calls == [
  [:acquire, lease_holder], [:acquire, lease_holder], [:release, lease_holder]
]

validation = adapter.validate(resource, operation)
raise 'release validation failed' unless validation.state == :succeeded
raise 'validation did not pin all four release inputs' unless validation.details.keys.sort == ForemanRelease::RuntimeAdapter::INPUT_DIGESTS.keys.sort
raise 'rendered cluster preflight was not executed' unless preflight.calls.length == 1 && preflight.calls.first.last == 'platform'
raise 'Secret values were not written with mode 0600' unless runner.values_modes.all? { |mode| mode == 0o600 }

valid_application_values = kubernetes.application_values
application_config = YAML.safe_load(valid_application_values)
application_config['smartProxy']['executionRegistration']['url'] = 'https://wrong-execution-service:8443'
kubernetes.application_values = YAML.dump(application_config)
begin
  adapter.validate(resource, operation)
  raise 'mismatched execution proxy registration URL was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('registration URL must be')
ensure
  kubernetes.application_values = valid_application_values
end

valid_execution_values = kubernetes.execution_values
execution_config = YAML.safe_load(valid_execution_values)
execution_config['smokeTest']['foremanCertificateSecret'] = 'another-foreman-certificate'
kubernetes.execution_values = YAML.dump(execution_config)
begin
  adapter.validate(resource, operation)
  raise 'mismatched Foreman client certificate Secret was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('application Foreman certificate Secret')
ensure
  kubernetes.execution_values = valid_execution_values
end

execution_config = YAML.safe_load(valid_execution_values)
execution_config['networkPolicy']['ingress'] = {'peers' => [{
  'podSelector' => {
    'matchLabels' => {
      'app.kubernetes.io/instance' => 'another-application',
      'app.kubernetes.io/component' => 'foreman'
    }
  }
}]}
kubernetes.execution_values = YAML.dump(execution_config)
begin
  adapter.validate(resource, operation)
  raise 'execution proxy ingress excluding the registration Job was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('rejects its Foreman registration Job')
ensure
  kubernetes.execution_values = valid_execution_values
end

operation.merge!(validation.details)

runner.existing_releases = ['foreman']
begin
  adapter.validate(resource, operation)
  raise 'unmanaged existing Helm release was adopted implicitly'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('application.adoptExisting=true')
end
resource['spec']['application']['adoptExisting'] = true
raise 'explicit Helm release adoption was rejected' unless adapter.validate(resource, operation).state == :succeeded
resource['spec']['application']['adoptExisting'] = false
runner.existing_releases = []

conflict = Marshal.load(Marshal.dump(resource))
conflict['metadata']['name'] = 'conflicting-release'
conflict['metadata']['uid'] = '87654321-4321-4321-4321-cba987654321'
kubernetes.releases_list = [resource, conflict]
begin
  adapter.validate(resource, operation)
  raise 'two ForemanRelease objects were allowed to own the same Helm releases'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('conflicting-release already owns')
ensure
  kubernetes.releases_list = [resource]
end

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

application_render = runner.renders.fetch('foreman')
desired_foreman_config = application_render.find do |item|
  item['kind'] == 'ConfigMap' && item.dig('metadata', 'name').end_with?('-foreman-config')
end
existing_foreman_config = Marshal.load(Marshal.dump(desired_foreman_config))
existing_foreman_config['metadata']['resourceVersion'] = '40'
existing_foreman_config['metadata']['labels']['app.kubernetes.io/managed-by'] = 'Helm'
existing_foreman_config['metadata']['annotations'] = {
  'meta.helm.sh/release-name' => 'foreman',
  'meta.helm.sh/release-namespace' => 'platform'
}
existing_foreman_config['data'] = {'stale' => 'configuration'}
kubernetes.replace('configmaps', [existing_foreman_config])

first_migration = adapter.ensure_migrations(resource, operation)
raise 'initial migration reconciliation did not remain pending' unless first_migration.state == :pending
raise 'submitted migration Job names were not checkpointed' unless first_migration.details.fetch(:migrationJobs).length == 3
if runner.calls.map(&:first).any? { |command| command.first(2) == %w[helm upgrade] && command.include?('foreman') }
  raise 'application workloads were submitted before migrations completed'
end
migration_jobs = kubernetes.created.select do |item|
  ForemanRelease::RuntimeAdapter::MIGRATION_COMPONENTS.include?(item.dig('metadata', 'labels', 'app.kubernetes.io/component'))
end
raise 'controller did not submit all migration Jobs directly' unless migration_jobs.length == 3
unless migration_jobs.all? { |job| job.dig('metadata', 'ownerReferences', 0, 'uid') == resource.dig('metadata', 'uid') }
  raise 'migration Jobs are not owned by the ForemanRelease'
end
prepared_kinds = kubernetes.created_resources.each_with_object(Hash.new(0)) do |item, counts|
  counts[item['kind']] += 1
end
unless prepared_kinds.slice('ConfigMap', 'PersistentVolumeClaim', 'ServiceAccount') == {
  'ConfigMap' => 1, 'PersistentVolumeClaim' => 1, 'ServiceAccount' => 1
}
  raise "migration prerequisites were not prepared: #{prepared_kinds.inspect}"
end
updated_foreman_config = kubernetes.resource('platform', 'configmap', desired_foreman_config.dig('metadata', 'name'))
unless updated_foreman_config['data'] == desired_foreman_config['data']
  raise 'existing migration ConfigMap was not updated before starting Jobs'
end

kubernetes.replace('jobs', migration_jobs.map { |job| complete_job(job) })
migrations = adapter.ensure_migrations(resource, operation)
raise 'completed migrations were not adopted' unless migrations.state == :succeeded
raise 'migration Job names were not recorded' unless migrations.details.fetch(:migrationJobs).length == 3

runner.existing_releases = ['foreman']
raise 'controller-owned Helm release required re-adoption' unless adapter.validate(resource, operation).state == :succeeded
runner.existing_releases = []

application_submission = adapter.ensure_application(resource, operation)
raise 'application submission did not remain pending' unless application_submission.state == :pending
unless application_submission.details == {applicationSubmittedRevision: 2}
  raise 'application submission did not expose its Helm revision'
end
upgrade = runner.calls.map(&:first).find { |command| command.first(2) == %w[helm upgrade] && command.include?('foreman') }
raise 'application Helm release was not submitted after migrations' unless upgrade
raise 'runtime adapter used blocking Helm wait' if upgrade.any? { |argument| argument.start_with?('--wait') }
raise 'application operation ID was not passed to Helm' unless upgrade.include?("releaseOperation.id=#{operation.fetch('id')}")
unless upgrade.include?('releaseOperation.skipMigrationJobs=true')
  raise 'application rollout attempted to recreate controller-owned migration Jobs'
end

application_render = runner.renders.fetch('foreman')
deployments = application_render.select { |item| item['kind'] == 'Deployment' }.map { |item| available_deployment(item) }
application_upgrades = runner.calls.count do |command, _stdin|
  command.first(2) == %w[helm upgrade] && command.include?('foreman')
end
kubernetes.replace('deployments', deployments.drop(1))
partial_application = adapter.ensure_application(resource, operation)
raise 'partial application workload set was not repaired' unless partial_application.state == :pending
unless runner.calls.count { |command, _stdin| command.first(2) == %w[helm upgrade] && command.include?('foreman') } == application_upgrades + 1
  raise 'partial application workload set did not resubmit Helm ownership'
end
kubernetes.replace('deployments', deployments)
registration_jobs = application_render.select do |item|
  item['kind'] == 'Job' && item.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'pulp-registration'
end
kubernetes.replace('jobs', migration_jobs.map { |job| complete_job(job) })
missing_registration = adapter.ensure_application(resource, operation)
raise 'missing Pulp registration Job was not repaired' unless missing_registration.state == :pending
kubernetes.replace('jobs', migration_jobs.map { |job| complete_job(job) } + registration_jobs.map { |job| complete_job(job) })
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
unless proxy_submission.details == {executionProxySubmittedRevision: 4}
  raise 'execution proxy submission did not expose its Helm revision'
end
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

registration = adapter.ensure_final_smoke(resource, operation)
raise 'execution proxy registration Job was not submitted asynchronously' unless registration.state == :pending
registration_job = kubernetes.created.last
raise 'registration Job has the wrong component' unless registration_job.dig('metadata', 'labels', 'app.kubernetes.io/component') ==
                                                    'execution-proxy-registration'
registration_script = registration_job.dig('spec', 'template', 'spec', 'containers', 0, 'command').join("\n")
raise 'registration Job does not verify exact Foreman features' unless registration_script.include?('proxy.features.reload.pluck(:name).sort')
verification_jobs = kubernetes.created.reject do |job|
  ForemanRelease::RuntimeAdapter::MIGRATION_COMPONENTS.include?(job.dig('metadata', 'labels', 'app.kubernetes.io/component'))
end
raise 'application verification Jobs reused a name' unless verification_jobs.map { |job| job.dig('metadata', 'name') }.uniq.length == 2
kubernetes.replace('jobs', kubernetes.resources('platform', 'jobs').map { |job| complete_job(job) })

final_application_smoke = adapter.ensure_final_smoke(resource, operation)
raise 'final application smoke Job was not submitted asynchronously' unless final_application_smoke.state == :pending
verification_jobs = kubernetes.created.reject do |job|
  ForemanRelease::RuntimeAdapter::MIGRATION_COMPONENTS.include?(job.dig('metadata', 'labels', 'app.kubernetes.io/component'))
end
raise 'verification Jobs did not receive distinct names' unless verification_jobs.map { |job| job.dig('metadata', 'name') }.uniq.length == 3
kubernetes.replace('jobs', kubernetes.resources('platform', 'jobs').map { |job| complete_job(job) })

execution_smoke = adapter.ensure_final_smoke(resource, operation)
raise 'execution mTLS smoke Job was not submitted asynchronously' unless execution_smoke.state == :pending
execution_job = kubernetes.created.last
raise 'execution smoke Job has the wrong Helm instance' unless execution_job.dig('metadata', 'labels', 'app.kubernetes.io/instance') == 'execution'
raise 'execution smoke Job does not verify the proxy Service' unless execution_job.dig('spec', 'template', 'spec', 'containers', 0, 'env').any? do |entry|
  entry['name'] == 'PROXY_FEATURES_URL' && entry['value'] == 'https://execution-foreman-execution-proxy:8443/features'
end
verification_jobs = kubernetes.created.reject do |job|
  ForemanRelease::RuntimeAdapter::MIGRATION_COMPONENTS.include?(job.dig('metadata', 'labels', 'app.kubernetes.io/component'))
end
raise 'four release verification Jobs did not receive distinct names' unless verification_jobs.map { |job| job.dig('metadata', 'name') }.uniq.length == 4
kubernetes.replace('jobs', kubernetes.resources('platform', 'jobs').map { |job| complete_job(job) })
raise 'completed paired final smoke gate was not adopted' unless adapter.ensure_final_smoke(resource, operation).state == :succeeded

owner = resource.dig('metadata', 'uid')
historical_jobs = (3..6).map do |generation|
  job = {
    'apiVersion' => 'batch/v1',
    'kind' => 'Job',
    'metadata' => {
      'name' => "foreman-history-g#{generation}",
      'creationTimestamp' => "2026-09-2#{generation}T12:00:00Z",
      'labels' => {
        ForemanRelease::RuntimeAdapter::OWNER_LABEL => owner,
        ForemanRelease::RuntimeAdapter::OPERATION_LABEL => "#{owner}-g#{generation}",
        ForemanRelease::RuntimeAdapter::INSTANCE_LABEL => 'foreman',
        ForemanRelease::RuntimeAdapter::COMPONENT_LABEL => 'smoke-test'
      }
    }
  }
  generation == 3 ? job : complete_job(job)
end
kubernetes.replace('jobs', kubernetes.resources('platform', 'jobs') + historical_jobs)
cleanup = adapter.prune_operation_history(resource, operation)
raise 'operation history cleanup did not succeed' unless cleanup.state == :succeeded
unless kubernetes.deleted == [['jobs', 'foreman-history-g4']]
  raise "history cleanup removed an unsafe set: #{kubernetes.deleted.inspect}"
end

puts 'Runtime adapter pins inputs, adopts paired resources, and safely bounds completed Job history.'
