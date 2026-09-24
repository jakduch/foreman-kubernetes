#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'

class FakeSidekiqConfig
  attr_reader :callbacks

  def initialize
    @callbacks = {}
  end

  def on(event, &callback)
    @callbacks[event] = callback
  end
end

module Sidekiq
  class << self
    attr_reader :test_config

    def configure_server
      @test_config = FakeSidekiqConfig.new
      yield @test_config
    end
  end
end

$LOADED_FEATURES << 'sidekiq.rb'

Dir.mktmpdir do |directory|
  readiness = File.join(directory, 'runtime', 'ready')
  FileUtils.mkdir_p(File.dirname(readiness))
  File.write(readiness, 'stale')
  ENV['DYNFLOW_READINESS_FILE'] = readiness

  load File.expand_path('../charts/foreman-stack/files/dynflow-lifecycle.rb', __dir__)
  abort 'stale readiness survived process initialization' if File.exist?(readiness)

  callbacks = Sidekiq.test_config.callbacks
  abort 'Sidekiq startup hook is missing' unless callbacks[:startup]
  abort 'Sidekiq quiet hook is missing' unless callbacks[:quiet]
  abort 'Sidekiq shutdown hook is missing' unless callbacks[:shutdown]

  callbacks.fetch(:startup).call
  abort 'startup did not publish readiness' unless File.read(readiness).strip == Process.pid.to_s

  callbacks.fetch(:quiet).call
  abort 'quiet did not remove readiness' if File.exist?(readiness)

  callbacks.fetch(:startup).call
  callbacks.fetch(:shutdown).call
  abort 'shutdown did not remove readiness' if File.exist?(readiness)
end

puts 'Dynflow lifecycle rejects stale state and follows Sidekiq startup, quiet, and shutdown.'
