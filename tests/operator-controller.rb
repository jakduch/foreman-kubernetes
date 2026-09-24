#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'stringio'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/controller').to_s

class ControllerClient
  attr_accessor :error

  def initialize(releases)
    @releases = releases
    @error = nil
  end

  def releases(namespace)
    raise @error if @error
    raise 'controller escaped its namespace' unless namespace == 'platform'

    @releases
  end
end

class ControllerReconciler
  attr_reader :names

  def initialize
    @names = []
  end

  def reconcile(resource)
    name = resource.dig('metadata', 'name')
    @names << name
    raise 'isolated failure' if name == 'broken'

    :requeue
  end
end

releases = %w[foreman broken second].map do |name|
  {
    'metadata' => {'name' => name, 'generation' => 1},
    'status' => {'phase' => 'Preflight'}
  }
end
client = ControllerClient.new(releases)
reconciler = ControllerReconciler.new
output = StringIO.new
controller = ForemanRelease::Controller.new(
  namespace: 'platform',
  kubernetes_client: client,
  reconciler: reconciler,
  output: output
)
controller.run_once
raise 'one failed resource stopped the reconciliation batch' unless reconciler.names == %w[foreman broken second]

events = output.string.lines.map { |line| JSON.parse(line) }
raise 'successful reconciliation was not logged' unless events.any? { |event| event['event'] == 'release_reconciled' && event['release'] == 'foreman' }
failure = events.find { |event| event['event'] == 'release_reconcile_failed' }
raise 'per-resource failure was not logged' unless failure && failure['release'] == 'broken'
raise 'controller log exposed a release spec' if events.any? { |event| event.key?('spec') }

client.error = RuntimeError.new('API unavailable')
controller.run_once
events = output.string.lines.map { |line| JSON.parse(line) }
raise 'list failure was not isolated and logged' unless events.last['event'] == 'release_list_failed'

ticks = []
looping_client = ControllerClient.new([])
looping = nil
looping = ForemanRelease::Controller.new(
  namespace: 'platform',
  kubernetes_client: looping_client,
  reconciler: reconciler,
  poll_seconds: 3,
  sleeper: lambda do |seconds|
    ticks << seconds
    looping.stop
  end,
  output: StringIO.new
)
looping.run
raise 'controller ignored its poll interval or graceful stop' unless ticks == [3]

puts 'Controller isolates release failures and stops gracefully.'
