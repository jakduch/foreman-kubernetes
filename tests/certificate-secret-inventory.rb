#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'
require 'yaml'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/manifest_requirements').to_s

application = YAML.load_stream(File.read(ARGV.fetch(0))).compact
execution = YAML.load_stream(File.read(ARGV.fetch(1))).compact

def assert_keys(documents, expected)
  actual = ForemanRelease::ManifestRequirements.new(documents).secrets
  expected.each do |name, keys|
    missing = keys - Array(actual[name])
    abort "Secret #{name} inventory is missing keys: #{missing.join(', ')}" unless missing.empty?
  end
end

assert_keys(
  application,
  {
    'foreman-certificates' => %w[ca.crt client_cert.pem client_key.pem],
    'candlepin-certificates' => %w[candlepin-ca.crt candlepin-ca.key tomcat.crt tomcat.key],
    'pulp-control-proxy-certificates' => %w[ca.crt tls.crt tls.key],
    'foreman-database-ca' => %w[db-ca.crt],
    'candlepin-database-ca' => %w[db-ca.crt],
    'pulp-database-ca' => %w[db-ca.crt],
    'valkey-ca' => %w[ca.crt]
  }
)
assert_keys(
  execution,
  {
    'foreman-execution-proxy-tls' => %w[ca.crt tls.crt tls.key],
    'foreman-execution-proxy-foreman-client' => %w[ca.crt tls.crt tls.key],
    'foreman-certificates' => %w[client_cert.pem client_key.pem]
  }
)

puts 'Certificate and private-key Secret inventory covers application and execution mounts.'
