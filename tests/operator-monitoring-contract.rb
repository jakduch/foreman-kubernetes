#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} DEFAULT_RENDER MONITORING_RENDER" unless ARGV.length == 2

default_documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
monitoring_documents = YAML.load_stream(File.read(ARGV.fetch(1))).compact

service = default_documents.find { |item| item['kind'] == 'Service' }
abort 'operator metrics Service is missing' unless service
abort 'NotReady controller metrics disappear from discovery' unless service.dig('spec', 'publishNotReadyAddresses') == true
abort 'PrometheusRule was enabled without an explicit dependency' if default_documents.any? { |item| item['kind'] == 'PrometheusRule' }

rule = monitoring_documents.find { |item| item['kind'] == 'PrometheusRule' }
abort 'enabled PrometheusRule is missing' unless rule
rules = Array(rule.dig('spec', 'groups')).flat_map { |group| Array(group['rules']) }
expected = %w[
  ForemanReleaseControllerMetricsMissing
  ForemanReleaseControllerNotReady
  ForemanReleaseControllerLeaderUnavailable
  ForemanReleaseControllerCycleFailures
]
names = rules.map { |item| item['alert'] }
abort "unexpected operator alerts: #{names.join(', ')}" unless names.sort == expected.sort
expressions = rules.map { |item| item['expr'].to_s }.join('\n')
%w[
  foreman_release_controller_running
  foreman_release_controller_ready
  foreman_release_controller_leader
  foreman_release_controller_cycles_total
].each do |metric|
  abort "alerts do not consume #{metric}" unless expressions.include?(metric)
end

puts 'Operator monitoring keeps failed candidates discoverable and packages four opt-in alerts.'
