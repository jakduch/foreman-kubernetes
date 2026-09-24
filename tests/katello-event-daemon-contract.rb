#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
component = 'katello-event-daemon'

daemon = documents.find do |resource|
  resource['kind'] == 'Deployment' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == component
end
abort 'dedicated Katello event daemon Deployment is missing' unless daemon
abort 'Katello event daemon must remain a singleton' unless daemon.dig('spec', 'replicas') == 1
abort 'Katello event daemon must use Recreate' unless daemon.dig('spec', 'strategy', 'type') == 'Recreate'

containers = Array(daemon.dig('spec', 'template', 'spec', 'containers'))
container = containers.find { |candidate| candidate['name'] == component }
abort 'Katello event daemon container is missing' unless container
abort 'Katello event daemon must run the chart watchdog' unless Array(container['command']).last == '/opt/foreman-kubernetes/katello-event-daemon.rb'

env = Array(container['env']).to_h { |item| [item['name'], item['value']] }
abort 'dedicated process must enable the Katello event daemon' unless env['KATELLO_EVENT_DAEMON_ENABLED'] == 'true'
abort 'Katello event daemon heartbeat path is missing' unless env['KATELLO_EVENT_DAEMON_HEARTBEAT']

%w[startupProbe readinessProbe livenessProbe].each do |probe|
  command = Array(container.dig(probe, 'exec', 'command')).join(' ')
  abort "#{probe} does not inspect the event daemon heartbeat" unless command.include?('KATELLO_EVENT_DAEMON_HEARTBEAT')
end

explicit_enablers = documents.each_with_object([]) do |resource, result|
  template = resource.dig('spec', 'template')
  next unless template

  Array(template.dig('spec', 'containers')).each do |candidate|
    setting = Array(candidate['env']).find { |item| item['name'] == 'KATELLO_EVENT_DAEMON_ENABLED' }
    result << [resource.dig('metadata', 'name'), candidate['name']] if setting&.fetch('value', nil) == 'true'
  end
end
abort "event daemon enabled by multiple containers: #{explicit_enablers.inspect}" unless explicit_enablers.length == 1

config = documents.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name').to_s.end_with?('-foreman-config')
end
katello_yaml = config&.dig('data', 'katello.yaml').to_s
watchdog = config&.dig('data', 'katello-event-daemon.rb').to_s
abort 'Katello settings do not default the embedded daemon off' unless katello_yaml.include?("ENV.fetch('KATELLO_EVENT_DAEMON_ENABLED', 'false')")
abort 'Katello event daemon watchdog is missing from generated configuration' unless watchdog.include?('Runner.start')

egress = documents.find do |resource|
  resource['kind'] == 'NetworkPolicy' && resource.dig('metadata', 'name').to_s.end_with?('-foreman-egress')
end
components = Array(egress&.dig('spec', 'podSelector', 'matchExpressions')).find do |expression|
  expression['key'] == 'app.kubernetes.io/component'
end
abort 'Katello event daemon is not covered by Foreman egress policy' unless Array(components&.fetch('values', nil)).include?(component)

puts 'Katello event daemon has one explicit owner with heartbeat and egress coverage.'
