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

abort 'Pulp API Gunicorn timeout differs from the image contract' unless option(api_args, '--timeout') == '90'
abort 'Pulp API worker recycling is missing' unless option(api_args, '--max-requests') == '800'
abort 'Pulp API worker recycling jitter is missing' unless option(api_args, '--max-requests-jitter') == '100'
abort 'Pulp content Gunicorn timeout differs from the image contract' unless option(content_args, '--timeout') == '90'
abort 'Pulp content unexpectedly received the API worker recycling flag' if content_args.include?('--max-requests')

puts 'Pulp process settings preserve the official image wrapper contract.'
