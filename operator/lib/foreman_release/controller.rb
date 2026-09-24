# frozen_string_literal: true

require 'json'
require 'time'

module ForemanRelease
  class Controller
    def initialize(namespace:, kubernetes_client:, reconciler:, leader_elector:, poll_seconds: 5,
                   sleeper: ->(seconds) { sleep(seconds) }, output: $stdout)
      raise ArgumentError, 'controller namespace is required' if namespace.to_s.empty?
      raise ArgumentError, 'poll interval must be at least one second' if poll_seconds < 1

      @namespace = namespace
      @kubernetes_client = kubernetes_client
      @reconciler = reconciler
      @leader_elector = leader_elector
      @poll_seconds = poll_seconds
      @sleeper = sleeper
      @output = output
      @stopping = false
      @leadership_state = nil
    end

    def run
      log('info', 'controller_started', namespace: @namespace, pollSeconds: @poll_seconds)
      begin
        until @stopping
          run_once
          @sleeper.call(@poll_seconds) unless @stopping
        end
      ensure
        @leader_elector.release
      end
      log('info', 'controller_stopped', namespace: @namespace)
    end

    def run_once
      leadership = @leader_elector.acquire
      unless leadership.state == :succeeded
        log_leadership('standby', leadership.message)
        return :standby
      end
      log_leadership('leader', leadership.message)
      @kubernetes_client.releases(@namespace).each do |resource|
        reconcile(resource)
      end
    rescue StandardError => error
      log('error', 'controller_cycle_failed', error: error.class.name, message: error.message)
    end

    def stop
      @stopping = true
    end

    private

    def log_leadership(state, message)
      return if @leadership_state == state

      @leadership_state = state
      log('info', 'leadership_changed', state: state, message: message)
    end

    def reconcile(resource)
      name = resource.dig('metadata', 'name').to_s
      result = @reconciler.reconcile(resource)
      log(
        'info', 'release_reconciled',
        release: name,
        generation: resource.dig('metadata', 'generation'),
        phase: resource.dig('status', 'phase') || 'Pending',
        result: result
      )
    rescue StandardError => error
      log(
        'error', 'release_reconcile_failed',
        release: name,
        error: error.class.name,
        message: error.message
      )
    end

    def log(level, event, fields)
      @output.puts(JSON.generate({level: level, event: event, time: Time.now.utc.iso8601}.merge(fields)))
      @output.flush
    end
  end
end
