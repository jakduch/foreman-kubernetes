#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV[0])).compact
ingress = documents.find do |resource|
  resource['kind'] == 'Ingress' && resource.dig('metadata', 'name').to_s.end_with?('-pulp-content')
end
abort 'Pulp content Ingress is missing' unless ingress

paths = Array(ingress.dig('spec', 'rules')).flat_map do |rule|
  Array(rule.dig('http', 'paths'))
end
path_map = paths.each_with_object({}) do |path, result|
  result[path['path']] = path.dig('backend', 'service', 'name')
end
content_service = documents.find do |resource|
  resource['kind'] == 'Service' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'pulp-content'
end
abort 'Pulp content Service is missing' unless content_service

expected_service = content_service.dig('metadata', 'name')
%w[/pulp/content /pulp/container /pulp/deb].each do |path|
  abort "#{path} is not routed to Pulp content" unless path_map[path] == expected_service
end

abort 'Pulp administrative API must not be public' if path_map.keys.any? { |path| path.start_with?('/pulp/api/') }

puts 'Pulp file, container, and Debian content routes are exposed without the administrative API.'
