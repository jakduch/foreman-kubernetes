#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact

def deployment(documents, component)
  documents.find do |resource|
    resource['kind'] == 'Deployment' &&
      resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == component
  end
end

def container_args(resource, name)
  containers = Array(resource&.dig('spec', 'template', 'spec', 'containers'))
  Array(containers.find { |container| container['name'] == name }&.fetch('args', nil))
end

def option(args, name)
  index = args.index(name)
  index && args[index + 1]
end

api_args = container_args(deployment(documents, 'pulp-api'), 'pulp-api')
content_args = container_args(deployment(documents, 'pulp-content'), 'pulp-content')
api = deployment(documents, 'pulp-api')
content = deployment(documents, 'pulp-content')
worker = deployment(documents, 'pulp-worker')
worker_container = Array(worker&.dig('spec', 'template', 'spec', 'containers'))
  .find { |container| container['name'] == 'pulp-worker' }

abort 'Pulp API Gunicorn timeout differs from the image contract' unless option(api_args, '--timeout') == '90'
abort 'Pulp API graceful timeout is missing' unless option(api_args, '--graceful-timeout') == '120'
abort 'Pulp API worker recycling is missing' unless option(api_args, '--max-requests') == '800'
abort 'Pulp API worker recycling jitter is missing' unless option(api_args, '--max-requests-jitter') == '100'
abort 'Pulp content Gunicorn timeout differs from the image contract' unless option(content_args, '--timeout') == '90'
abort 'Pulp content graceful timeout is missing' unless option(content_args, '--graceful-timeout') == '120'
abort 'Pulp content unexpectedly received the API worker recycling flag' if content_args.include?('--max-requests')
[api, content].each do |service|
  component = service.dig('metadata', 'labels', 'app.kubernetes.io/component')
  pod_spec = service.dig('spec', 'template', 'spec')
  container = Array(pod_spec['containers']).first
  abort "#{component} has insufficient shutdown time" unless pod_spec['terminationGracePeriodSeconds'] == 150
  unless container.dig('lifecycle', 'preStop', 'exec', 'command') == ['/usr/bin/sleep', '10']
    abort "#{component} does not drain Service endpoints before Gunicorn shutdown"
  end
end
abort 'Pulp worker is missing' unless worker_container
unless worker.dig('spec', 'template', 'spec', 'terminationGracePeriodSeconds') == 3600
  abort 'Pulp worker cannot finish long tasks during shutdown'
end
readiness_command = Array(worker_container.dig('readinessProbe', 'exec', 'command')).join("\n")
unless readiness_command.include?('AppStatus.objects.online()') &&
       readiness_command.include?('name__endswith=f"@{hostname}"')
  abort 'Pulp worker readiness does not verify its database heartbeat'
end

puts 'Pulp process settings preserve request recycling and graceful worker lifecycle contracts.'
