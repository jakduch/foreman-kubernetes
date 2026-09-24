# frozen_string_literal: true

require 'thread'
require 'time'

module ForemanRelease
  class ControllerStatus
    def initialize(clock: -> { Time.now.utc })
      @clock = clock
      @mutex = Mutex.new
      @running = false
      @role = :unknown
      @successful_cycles = 0
      @failed_cycles = 0
      @last_success_at = nil
    end

    def started
      update { @running = true }
    end

    def stopped
      update do
        @running = false
        @role = :unknown
      end
    end

    def role_changed(role)
      update { @role = role.to_sym }
    end

    def cycle_succeeded
      update do
        @successful_cycles += 1
        @last_success_at = @clock.call.utc
      end
    end

    def cycle_failed
      update do
        @failed_cycles += 1
        @role = :unknown
      end
    end

    def snapshot
      @mutex.synchronize do
        {
          running: @running,
          role: @role,
          successful_cycles: @successful_cycles,
          failed_cycles: @failed_cycles,
          last_success_at: @last_success_at,
          observed_at: @clock.call.utc
        }
      end
    end

    private

    def update(&block)
      @mutex.synchronize(&block)
    end
  end
end
