# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'
require 'tmpdir'
require 'yaml'
require_relative 'command_runner'
require_relative 'kubernetes_client'
require_relative 'lease_manager'
require_relative 'reconciler'
require_relative 'release_inputs'

module ForemanRelease
  class RuntimeAdapter
    MIGRATION_COMPONENTS = %w[candlepin-migrate pulp-migrate foreman-migrate].freeze
    REGISTRATION_COMPONENT = 'pulp-registration'
    OPERATION_LABEL = 'platform.theforeman.org/release-operation'
    OWNER_LABEL = 'platform.theforeman.org/release-owner'
    COMPONENT_LABEL = 'app.kubernetes.io/component'
    INSTANCE_LABEL = 'app.kubernetes.io/instance'
    INPUT_DIGESTS = {
      'applicationValuesSha256' => :application_values,
      'executionProxyValuesSha256' => :execution_values,
      'applicationProfileSha256' => :application_profile,
      'executionProxyProfileSha256' => :execution_proxy_profile
    }.freeze

    ReleaseContext = Struct.new(
      :profiles,
      :application_values,
      :execution_values,
      :digests,
      keyword_init: true
    )

    def initialize(root:, runner: CommandRunner.new, kubernetes_client: nil, lease_manager: nil)
      @root = Pathname.new(root).realpath
      @runner = runner
      @kubernetes_client = kubernetes_client || KubernetesClient.new(runner: runner)
      @lease_manager = lease_manager || LeaseManager.new(runner: runner)
      @catalog = ReleaseCatalog.load(@root)
      @values_reader = ValuesReader.new(@kubernetes_client)
      @application_chart = @root.join('charts/foreman-stack').to_s
      @execution_chart = @root.join('charts/foreman-execution-proxy').to_s
    end

    def validate(resource, operation)
      context = resolve_context(resource)
      with_value_files(context) do |application_values, execution_values|
        lint_chart(@application_chart, application_values, context.profiles.application_path, resource, operation)
        lint_chart(@execution_chart, execution_values, context.profiles.execution_proxy_path, resource, operation)
        application = render_chart(
          application_release(resource), @application_chart, application_values,
          context.profiles.application_path, resource, operation
        )
        execution = render_chart(
          execution_release(resource), @execution_chart, execution_values,
          context.profiles.execution_proxy_path, resource, operation
        )
        validate_rendered_contract!(application, execution)
      end

      Observation.new(
        state: :succeeded,
        message: "validated compatibility set #{context.profiles.name}",
        details: context.digests
      )
    end

    def acquire_lease(resource, operation)
      @lease_manager.acquire(resource, operation)
    end

    def renew_lease(resource, operation)
      @lease_manager.renew(resource, operation)
    end

    def release_lease(resource, operation)
      @lease_manager.release(resource, operation)
    end

    def ensure_migrations(resource, operation)
      with_rendered_application(resource, operation) do |context, values_path, resources|
        expected = jobs(resources, MIGRATION_COMPONENTS)
        raise InvalidRelease, 'application chart did not render all three migration Jobs' unless expected.length == 3

        live = operation_resources(resource, operation, 'jobs')
        matching = live.select { |job| expected_names(expected).include?(job.dig('metadata', 'name')) }
        if matching.empty?
          upgrade(
            application_release(resource), @application_chart, values_path,
            context.profiles.application_path, resource, operation
          )
          return Observation.new(state: :pending, message: 'application release submitted; waiting for migration Jobs')
        end
        return incomplete_job_set(expected, matching, 'migration') unless matching.length == expected.length

        observe_jobs(matching, details: {migrationJobs: expected_names(expected).sort})
      end
    end

    def ensure_application(resource, operation)
      with_rendered_application(resource, operation) do |_context, _values_path, resources|
        expected_deployments = resources.select { |item| item['kind'] == 'Deployment' }
        raise InvalidRelease, 'application chart did not render any Deployments' if expected_deployments.empty?

        live_deployments = operation_resources(resource, operation, 'deployments')
        deployment_result = observe_deployments(expected_deployments, live_deployments)
        return deployment_result unless deployment_result.state == :succeeded

        expected_registration = jobs(resources, [REGISTRATION_COMPONENT])
        unless expected_registration.empty?
          live_jobs = operation_resources(resource, operation, 'jobs')
          registration = live_jobs.select do |job|
            expected_names(expected_registration).include?(job.dig('metadata', 'name'))
          end
          return incomplete_job_set(expected_registration, registration, 'Pulp registration') unless registration.length == expected_registration.length

          registration_result = observe_jobs(registration)
          return registration_result unless registration_result.state == :succeeded
        end

        Observation.new(
          state: :succeeded,
          message: 'application workloads and Pulp registration are available',
          details: {applicationRevision: helm_revision(resource, application_release(resource))}
        )
      end
    end

    def ensure_application_smoke(resource, operation)
      ensure_smoke(resource, operation, 'application-smoke')
    end

    def ensure_proxy(resource, operation)
      with_rendered_execution(resource, operation) do |context, values_path, resources|
        expected = resources.select { |item| item['kind'] == 'Deployment' }
        raise InvalidRelease, 'execution proxy chart must render exactly one Deployment' unless expected.length == 1

        live = operation_resources(resource, operation, 'deployments', instance: execution_release(resource))
        if live.empty?
          upgrade(
            execution_release(resource), @execution_chart, values_path,
            context.profiles.execution_proxy_path, resource, operation
          )
          return Observation.new(state: :pending, message: 'execution proxy release submitted')
        end

        result = observe_deployments(expected, live)
        return result unless result.state == :succeeded

        Observation.new(
          state: :succeeded,
          message: 'execution proxy is available',
          details: {executionProxyRevision: helm_revision(resource, execution_release(resource))}
        )
      end
    end

    def ensure_final_smoke(resource, operation)
      proxy = ensure_proxy(resource, operation)
      return proxy unless proxy.state == :succeeded

      ensure_smoke(resource, operation, 'final-smoke')
    end

    private

    def resolve_context(resource, operation = nil)
      profiles = @catalog.resolve(
        resource.dig('spec', 'compatibilitySet'),
        allow_candidate: resource.dig('spec', 'allowCandidate') == true
      )
      values = @values_reader.read(resource)
      content = {
        application_values: values.application,
        execution_values: values.execution_proxy,
        application_profile: File.binread(profiles.application_path),
        execution_proxy_profile: File.binread(profiles.execution_proxy_path)
      }
      digests = INPUT_DIGESTS.to_h do |status_key, content_key|
        [status_key, Digest::SHA256.hexdigest(content.fetch(content_key))]
      end
      if operation
        digests.each do |key, actual|
          expected = operation[key]
          raise InvalidRelease, "release input #{key} was not pinned during validation" if expected.to_s.empty?
          raise InvalidRelease, "release input #{key} changed during operation" unless expected == actual
        end
      end

      ReleaseContext.new(
        profiles: profiles,
        application_values: values.application,
        execution_values: values.execution_proxy,
        digests: digests
      )
    end

    def with_rendered_application(resource, operation)
      context = resolve_context(resource, operation)
      with_value_files(context) do |application_values, _execution_values|
        rendered = render_chart(
          application_release(resource), @application_chart, application_values,
          context.profiles.application_path, resource, operation
        )
        yield context, application_values, rendered
      end
    end

    def with_rendered_execution(resource, operation)
      context = resolve_context(resource, operation)
      with_value_files(context) do |_application_values, execution_values|
        rendered = render_chart(
          execution_release(resource), @execution_chart, execution_values,
          context.profiles.execution_proxy_path, resource, operation
        )
        yield context, execution_values, rendered
      end
    end

    def with_value_files(context)
      Dir.mktmpdir('foreman-release-values-') do |directory|
        application = secure_write(directory, 'application.yaml', context.application_values)
        execution = secure_write(directory, 'execution.yaml', context.execution_values)
        yield application, execution
      end
    end

    def secure_write(directory, name, content)
      path = File.join(directory, name)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(content) }
      path
    end

    def lint_chart(chart, values_path, profile_path, resource, operation)
      @runner.run(
        'helm', 'lint', chart, '--values', values_path, '--values', profile_path,
        *operation_arguments(resource, operation)
      )
    end

    def render_chart(release_name, chart, values_path, profile_path, resource, operation = nil)
      output = @runner.run(
        'helm', 'template', release_name, chart,
        '--namespace', resource.dig('metadata', 'namespace'),
        '--values', values_path, '--values', profile_path,
        *operation_arguments(resource, operation)
      )
      YAML.load_stream(output).compact
    rescue Psych::Exception => error
      raise InvalidRelease, "Helm rendered invalid YAML: #{error.message}"
    end

    def operation_arguments(resource, operation = nil)
      id = operation&.fetch('id', nil).to_s
      return [] if id.empty?

      [
        '--set-string', "releaseOperation.id=#{id}",
        '--set-string', "releaseOperation.ownerUid=#{resource.dig('metadata', 'uid')}"
      ]
    end

    def validate_rendered_contract!(application, execution)
      migration_components = jobs(application, MIGRATION_COMPONENTS).map { |job| job.dig('metadata', 'labels', COMPONENT_LABEL) }
      unless migration_components.sort == MIGRATION_COMPONENTS.sort
        raise InvalidRelease, 'application values must enable every migration Job'
      end
      raise InvalidRelease, 'application values must not enable maintenance mode' unless application.any? { |item| item['kind'] == 'Deployment' }
      raise InvalidRelease, 'application values must enable its smoke test' if jobs(application, ['smoke-test']).empty?
      raise InvalidRelease, 'execution proxy chart must render exactly one Deployment' unless execution.count { |item| item['kind'] == 'Deployment' } == 1
    end

    def upgrade(release_name, chart, values_path, profile_path, resource, operation)
      @runner.run(
        'helm', 'upgrade', '--install', release_name, chart,
        '--namespace', resource.dig('metadata', 'namespace'),
        '--history-max', '10',
        '--values', values_path, '--values', profile_path,
        *operation_arguments(resource, operation)
      )
    end

    def operation_resources(resource, operation, type, instance: application_release(resource))
      @kubernetes_client.resources(
        resource.dig('metadata', 'namespace'), type,
        labels: {
          OPERATION_LABEL => operation.fetch('id'),
          OWNER_LABEL => resource.dig('metadata', 'uid'),
          INSTANCE_LABEL => instance
        }
      )
    end

    def jobs(resources, components)
      resources.select do |item|
        item['kind'] == 'Job' && components.include?(item.dig('metadata', 'labels', COMPONENT_LABEL))
      end
    end

    def expected_names(resources)
      resources.map { |resource| resource.dig('metadata', 'name') }
    end

    def incomplete_job_set(expected, matching, description)
      missing = expected_names(expected) - expected_names(matching)
      Observation.new(
        state: :pending,
        message: "waiting for #{description} Jobs: #{missing.join(', ')}"
      )
    end

    def observe_jobs(resources, details: {})
      failed = resources.find { |job| condition_true?(job, 'Failed') }
      if failed
        condition = condition(failed, 'Failed')
        return Observation.new(
          state: :failed,
          message: "Job #{failed.dig('metadata', 'name')} failed: #{condition['reason'] || condition['message'] || 'unknown reason'}"
        )
      end
      incomplete = resources.reject { |job| condition_true?(job, 'Complete') }
      unless incomplete.empty?
        return Observation.new(
          state: :pending,
          message: "waiting for Jobs: #{expected_names(incomplete).join(', ')}"
        )
      end

      Observation.new(state: :succeeded, message: 'Jobs completed successfully', details: details)
    end

    def observe_deployments(expected, live)
      live_by_name = live.to_h { |deployment| [deployment.dig('metadata', 'name'), deployment] }
      missing = expected_names(expected).reject { |name| live_by_name.key?(name) }
      return Observation.new(state: :pending, message: "waiting for Deployments: #{missing.join(', ')}") unless missing.empty?

      expected_names(expected).each do |name|
        deployment = live_by_name.fetch(name)
        progressing = condition(deployment, 'Progressing')
        if progressing && progressing['status'] == 'False'
          return Observation.new(
            state: :failed,
            message: "Deployment #{name} failed: #{progressing['reason'] || progressing['message'] || 'not progressing'}"
          )
        end
        generation = Integer(deployment.dig('metadata', 'generation') || 0)
        observed = Integer(deployment.dig('status', 'observedGeneration') || 0)
        unless observed >= generation && condition_true?(deployment, 'Available')
          return Observation.new(state: :pending, message: "waiting for Deployment #{name} to become available")
        end
        desired = Integer(deployment.dig('spec', 'replicas') || 1)
        available = Integer(deployment.dig('status', 'availableReplicas') || 0)
        return Observation.new(state: :pending, message: "waiting for Deployment #{name} replicas") if available < desired
      end

      Observation.new(state: :succeeded, message: 'Deployments are available')
    end

    def condition(resource, type)
      Array(resource.dig('status', 'conditions')).find { |candidate| candidate['type'] == type }
    end

    def condition_true?(resource, type)
      condition(resource, type)&.fetch('status', nil) == 'True'
    end

    def ensure_smoke(resource, operation, stage)
      with_rendered_application(resource, operation) do |_context, _values_path, resources|
        template = jobs(resources, ['smoke-test']).first
        raise InvalidRelease, 'application smoke-test Job is disabled' unless template

        smoke = smoke_job(template, resource, operation, stage)
        live = operation_resources(resource, operation, 'jobs').select do |job|
          job.dig('metadata', 'name') == smoke.dig('metadata', 'name')
        end
        if live.empty?
          begin
            @kubernetes_client.create(resource.dig('metadata', 'namespace'), smoke)
          rescue CommandError => error
            raise unless error.stderr.include?('AlreadyExists')

            existing = @kubernetes_client.resource(
              resource.dig('metadata', 'namespace'), 'job', smoke.dig('metadata', 'name')
            )
            labels = existing.dig('metadata', 'labels') || {}
            unless labels[OPERATION_LABEL] == operation.fetch('id') &&
                   labels[OWNER_LABEL] == resource.dig('metadata', 'uid')
              raise InvalidRelease, "smoke Job #{smoke.dig('metadata', 'name')} belongs to another operation"
            end
          end
          return Observation.new(state: :pending, message: "#{stage} Job submitted")
        end

        result = observe_jobs(live)
        return result unless result.state == :succeeded

        Observation.new(state: :succeeded, message: "#{stage} passed")
      end
    end

    def smoke_job(template, resource, operation, stage)
      job = Marshal.load(Marshal.dump(template))
      job['metadata']['name'] = bounded_name("#{application_release(resource)}-#{stage}-#{operation.fetch('id')}")
      job['metadata'].delete('namespace')
      annotations = job.dig('metadata', 'annotations') || {}
      annotations.delete_if { |key, _value| key.start_with?('helm.sh/hook') }
      annotations['foreman-kubernetes.io/verification-stage'] = stage
      job['metadata']['annotations'] = annotations
      job['metadata']['ownerReferences'] = [{
        'apiVersion' => resource.fetch('apiVersion'),
        'kind' => resource.fetch('kind'),
        'name' => resource.dig('metadata', 'name'),
        'uid' => resource.dig('metadata', 'uid'),
        'controller' => true,
        'blockOwnerDeletion' => true
      }]
      job
    end

    def bounded_name(raw)
      return raw if raw.length <= 63

      "#{raw[0, 54].sub(/-+\z/, '')}-#{Digest::SHA256.hexdigest(raw)[0, 8]}"
    end

    def helm_revision(resource, release_name)
      status = JSON.parse(
        @runner.run(
          'helm', 'status', release_name,
          '--namespace', resource.dig('metadata', 'namespace'), '--output=json'
        )
      )
      Integer(status.fetch('version'))
    rescue JSON::ParserError, KeyError, ArgumentError, TypeError => error
      raise InvalidRelease, "cannot determine Helm revision for #{release_name}: #{error.message}"
    end

    def application_release(resource)
      resource.dig('spec', 'application', 'releaseName') || 'foreman'
    end

    def execution_release(resource)
      resource.dig('spec', 'executionProxy', 'releaseName') || 'execution'
    end
  end
end
