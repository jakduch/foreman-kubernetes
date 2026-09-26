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
expected_command = ['bin/rails', 'runner', 'Katello::EventDaemon::Runner.run_foreground']
abort 'Katello event daemon must use the upstream foreground runner' unless Array(container['command']) == expected_command

env = Array(container['env']).to_h { |item| [item['name'], item['value']] }
abort 'dedicated process must enable the Katello event daemon' unless env['KATELLO_EVENT_DAEMON_ENABLED'] == 'true'
abort 'Katello event daemon heartbeat path is missing' unless env['KATELLO_EVENT_DAEMON_HEARTBEAT']
abort 'Katello event daemon runtime directory is missing' unless env['KATELLO_EVENT_DAEMON_TMP_DIR'] == '/run/katello-event-daemon'

runtime_mount = Array(container['volumeMounts']).find { |mount| mount['name'] == 'katello-event-daemon-runtime' }
abort 'Katello event daemon runtime is not process-local' unless runtime_mount&.fetch('mountPath', nil) == '/run/katello-event-daemon'
runtime_volume = Array(daemon.dig('spec', 'template', 'spec', 'volumes')).find do |volume|
  volume['name'] == 'katello-event-daemon-runtime'
end
abort 'Katello event daemon runtime must use emptyDir' unless runtime_volume&.key?('emptyDir')

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
abort 'Katello settings do not default the embedded daemon off' unless katello_yaml.include?("ENV.fetch('KATELLO_EVENT_DAEMON_ENABLED', 'false')")
abort 'Katello settings do not configure the process-local runtime directory' unless katello_yaml.include?('KATELLO_EVENT_DAEMON_TMP_DIR')
abort 'chart still injects an event daemon implementation' if config&.dig('data')&.key?('katello-event-daemon.rb')

egress = documents.find do |resource|
  resource['kind'] == 'NetworkPolicy' && resource.dig('metadata', 'name').to_s.end_with?('-foreman-egress')
end
components = Array(egress&.dig('spec', 'podSelector', 'matchExpressions')).find do |expression|
  expression['key'] == 'app.kubernetes.io/component'
end
abort 'Katello event daemon is not covered by Foreman egress policy' unless Array(components&.fetch('values', nil)).include?(component)

puts 'Katello event daemon has one explicit owner with heartbeat and egress coverage.'
