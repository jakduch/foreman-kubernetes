# frozen_string_literal: true

require_relative 'state_machine'
require 'time'

module ForemanRelease
  Observation = Struct.new(:state, :message, :details, keyword_init: true)

  class Reconciler
    ACTIVE_PHASES = %w[Migrating RollingApplication RollingProxy].freeze
    PHASE_HANDLERS = {
      'Preflight' => [:validate, 'ValidationSucceeded', 'ValidationFailed'],
      'AcquiringLock' => [:acquire_lease, 'LeaseAcquired', 'LeaseFailed'],
      'Migrating' => [:ensure_migrations, 'MigrationsSucceeded', 'MigrationsFailed'],
      'RollingApplication' => [:ensure_application, 'ApplicationAvailable', 'ApplicationFailed'],
      'VerifyingApplication' => [:ensure_application_smoke, 'ApplicationSmokeSucceeded', 'ApplicationSmokeFailed'],
      'RollingProxy' => [:ensure_proxy, 'ExecutionProxyAvailable', 'ExecutionProxyFailed'],
      'Verifying' => [:ensure_final_smoke, 'FinalSmokeSucceeded', 'FinalSmokeFailed']
    }.freeze

    def initialize(state_machine:, adapter:, status_writer:, clock: -> { Time.now.utc.iso8601 })
      @state_machine = state_machine
      @adapter = adapter
      @status_writer = status_writer
      @clock = clock
    end

    def reconcile(resource)
      spec = resource.fetch('spec')
      status = resource.fetch('status', {})
      phase = status.fetch('phase', 'Pending')

      if start_required?(resource, phase)
        return persist_start(resource) unless spec.fetch('paused', false)

        return persist_pause(resource, status)
      end

      if phase == 'Ready' || phase == 'Blocked'
        return persist_pause(resource, status) if spec.fetch('paused', false)
        return persist_resume(resource, status) if paused?(status)

        return :idle
      end

      if spec.fetch('paused', false) && !ACTIVE_PHASES.include?(phase)
        return persist_pause(resource, status)
      end

      handler, success_event, failure_event = PHASE_HANDLERS.fetch(phase)
      observation = observe(handler, resource, status.fetch('operation', {}))

      if observation.state == :pending || observation.state == :busy
        if phase == 'AcquiringLock' && observation.state == :busy
          transition(resource, status, 'LeaseBusy', observation)
          return :requeue
        end

        persist_pause(resource, status) if spec.fetch('paused', false)
        return :requeue
      end

      if observation.state == :failed
        transition(resource, status, failure_event, observation)
        @adapter.release_lease(resource, status.fetch('operation', {}))
        return :blocked
      end

      unless observation.state == :succeeded
        raise ArgumentError, "#{handler} returned unsupported state #{observation.state.inspect}"
      end

      return persist_pause(resource, status) if spec.fetch('paused', false)

      result = transition(resource, status, success_event, observation)
      if result.status == 'Ready'
        @adapter.release_lease(resource, result.operation)
        :ready
      else
        :requeue
      end
    end

    private

    TransitionResult = Struct.new(:status, :operation, keyword_init: true)

    def start_required?(resource, phase)
      spec = resource.fetch('spec')
      status = resource.fetch('status', {})
      case phase
      when 'Pending'
        true
      when 'Ready'
        status['currentSet'] != spec.fetch('compatibilitySet')
      when 'Blocked'
        @state_machine.retry_allowed?(status, spec.fetch('retryToken', ''))
      else
        false
      end
    end

    def persist_start(resource)
      status = resource.fetch('status', {})
      phase = status.fetch('phase', 'Pending')
      event = case phase
              when 'Pending' then 'Reconcile'
              when 'Ready' then 'DesiredSetChanged'
              when 'Blocked' then 'RetryTokenChanged'
              end
      operation_id = "#{resource.dig('metadata', 'uid')}-g#{resource.dig('metadata', 'generation')}"
      decision = @state_machine.transition(
        status: status,
        event: event,
        generation: resource.dig('metadata', 'generation'),
        desired_set: resource.dig('spec', 'compatibilitySet'),
        retry_token: resource.dig('spec', 'retryToken').to_s,
        operation_id: operation_id,
        now: @clock.call
      )
      @status_writer.call(resource, decision.status)
      :requeue
    end

    def persist_pause(resource, status)
      paused_status = @state_machine.pause(
        status: status,
        generation: resource.dig('metadata', 'generation'),
        now: @clock.call
      )
      @status_writer.call(resource, paused_status)
      :paused
    end

    def persist_resume(resource, status)
      resumed_status = @state_machine.resume(
        status: status,
        generation: resource.dig('metadata', 'generation'),
        now: @clock.call
      )
      @status_writer.call(resource, resumed_status)
      :idle
    end

    def paused?(status)
      Array(status['conditions']).any? do |condition|
        condition['type'] == 'Paused' && condition['status'] == 'True'
      end
    end

    def observe(handler, resource, operation)
      value = @adapter.public_send(handler, resource, operation)
      return value if value.is_a?(Observation)

      Observation.new(state: value, details: {})
    rescue StandardError => error
      Observation.new(state: :failed, message: error.message, details: {})
    end

    def transition(resource, status, event, observation)
      decision = @state_machine.transition(
        status: status,
        event: event,
        generation: resource.dig('metadata', 'generation'),
        desired_set: resource.dig('spec', 'compatibilitySet'),
        retry_token: resource.dig('spec', 'retryToken').to_s,
        now: @clock.call,
        message: observation.message,
        details: observation.details || {}
      )
      @status_writer.call(resource, decision.status)
      TransitionResult.new(status: decision.status.fetch('phase'), operation: decision.status.fetch('operation', {}))
    end

  end
end
