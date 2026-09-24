#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'
require 'time'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/controller_status').to_s
require root.join('operator/lib/foreman_release/health_server').to_s

now = Time.iso8601('2026-09-25T00:00:00Z')
status = ForemanRelease::ControllerStatus.new(clock: -> { now })
server = ForemanRelease::HealthServer.new(
  status: status,
  port: 9393,
  readiness_max_staleness_seconds: 30
)

status.started
raise 'live controller failed liveness' unless server.response('GET', '/livez').first == 200
raise 'controller was ready before one successful cycle' unless server.response('GET', '/readyz').first == 503

status.role_changed(:leader)
status.cycle_succeeded
raise 'successful cycle did not make controller ready' unless server.response('GET', '/readyz').first == 200
metrics = server.response('GET', '/metrics').last
raise 'metrics omitted leadership' unless metrics.include?("foreman_release_controller_leader 1\n")
raise 'metrics omitted successful cycles' unless metrics.include?("result=\"success\"} 1\n")

status.cycle_failed
metrics = server.response('GET', '/metrics').last
raise 'metrics retained leadership after a failed API cycle' unless metrics.include?("foreman_release_controller_leader 0\n")
raise 'metrics omitted failed cycles' unless metrics.include?("result=\"failure\"} 1\n")

now += 31
raise 'stale controller remained ready' unless server.response('GET', '/readyz').first == 503
status.stopped
raise 'stopped controller remained live' unless server.response('GET', '/livez').first == 503
raise 'unsupported method was accepted' unless server.response('POST', '/metrics').first == 405

puts 'Controller health endpoint reports liveness, stale readiness, leadership, and cycle metrics.'
