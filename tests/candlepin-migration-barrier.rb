#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST EXPECT_BARRIER(true|false)" unless ARGV.length == 2

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
deployment = documents.find do |resource|
  resource['kind'] == 'Deployment' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'candlepin'
end
abort 'Candlepin Deployment is missing' unless deployment

barrier = Array(deployment.dig('spec', 'template', 'spec', 'initContainers')).find do |container|
  container['name'] == 'ensure-candlepin-migrations'
end
expected = ARGV.fetch(1) == 'true'
abort "Candlepin migration barrier expectation differs" unless !barrier.nil? == expected

if barrier
  command = Array(barrier['command'])
  unless command == ['/bin/bash', '/opt/foreman-kubernetes/candlepin-migrate.sh']
    abort "Candlepin barrier does not use the migration wrapper: #{command.inspect}"
  end

  env = Array(barrier['env']).to_h { |entry| [entry['name'], entry] }
  %w[CANDLEPIN_DATABASE_URL CANDLEPIN_DATABASE_USER LIQUIBASE_COMMAND_PASSWORD].each do |name|
    abort "Candlepin barrier lacks #{name}" unless env.key?(name)
  end

  mount = Array(barrier['volumeMounts']).find do |candidate|
    candidate['mountPath'] == '/opt/foreman-kubernetes/candlepin-migrate.sh'
  end
  abort 'Candlepin barrier migration wrapper is not mounted read-only' unless mount&.fetch('readOnly', false)
end

puts "Candlepin migration init barrier enabled=#{expected}."
