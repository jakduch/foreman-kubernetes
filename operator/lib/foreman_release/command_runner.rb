# frozen_string_literal: true

require 'open3'

module ForemanRelease
  class CommandError < StandardError
    attr_reader :command, :stderr, :exit_status

    def initialize(command, stderr, exit_status)
      @command = command
      @stderr = stderr
      @exit_status = exit_status
      super("command failed with exit status #{exit_status}: #{command.join(' ')}: #{stderr.strip}")
    end
  end

  class CommandRunner
    def run(*command, stdin_data: '')
      stdout, stderr, status = Open3.capture3(*command, stdin_data: stdin_data)
      raise CommandError.new(command, stderr, status.exitstatus) unless status.success?

      stdout
    end
  end
end
