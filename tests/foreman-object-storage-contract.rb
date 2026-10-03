#!/usr/bin/env ruby
# frozen_string_literal: true

require 'open3'
require 'yaml'

abort 'usage: foreman-object-storage-contract.rb DEFAULT S3 S3_EGRESS' unless ARGV.length == 3

load_resources = lambda do |path|
  YAML.load_stream(File.read(path)).compact
end

default, s3, s3_egress = ARGV.map { |path| load_resources.call(path) }
component = 'foreman-object-storage-test'
probes = s3.select do |resource|
  resource['kind'] == 'Pod' && resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == component
end
abort 'S3 profile must render exactly one Foreman object-storage test Pod' unless probes.length == 1
abort 'local profile must not render the Foreman object-storage test' if default.any? do |resource|
  resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == component
end

probe = probes.first
abort 'Foreman object-storage probe is not a Helm test' unless probe.dig('metadata', 'annotations', 'helm.sh/hook') == 'test'
unless probe.dig('metadata', 'annotations', 'helm.sh/hook-delete-policy') == 'before-hook-creation'
  abort 'Foreman object-storage probe deletes its evidence before Helm can collect logs'
end
pod = probe.fetch('spec')
abort 'Foreman object-storage probe mounts a service-account token' unless pod['automountServiceAccountToken'] == false
container = pod.fetch('containers').fetch(0)
script = container.fetch('args').join("\n")
%w[create_and_upload! blob.download blob.byte_size blob.purge].each do |contract|
  abort "Foreman object-storage probe does not exercise #{contract}" unless script.include?(contract)
end
abort 'Foreman object-storage probe does not cross the multipart threshold' unless script.include?('9 * 1024 * 1024')
_stdout, stderr, status = Open3.capture3('ruby', '-c', stdin_data: script)
abort "Foreman object-storage probe contains invalid Ruby: #{stderr}" unless status.success?

foreman_deployment = s3.find do |resource|
  resource['kind'] == 'Deployment' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'foreman'
end
abort 'S3 profile rendered no Foreman Deployment' unless foreman_deployment
foreman_container = foreman_deployment.dig('spec', 'template', 'spec', 'containers').find do |candidate|
  candidate['name'] == 'foreman'
end
unless container['resources'] == foreman_container['resources']
  abort 'Foreman object-storage probe does not use the Rails process resource envelope'
end

foreman_containers = s3.flat_map do |resource|
  Array(resource.dig('spec', 'template', 'spec', 'containers'))
end.select do |candidate|
  Array(candidate['env']).any? { |entry| entry['name'] == 'RAILS_ENV' }
end
abort 'S3 profile rendered no Foreman runtime containers' if foreman_containers.empty?
foreman_containers.each do |candidate|
  env = candidate.fetch('env').to_h { |entry| [entry.fetch('name'), entry] }
  abort 'Foreman process did not select the S3 Active Storage service' unless env.dig('FOREMAN_ACTIVE_STORAGE_SERVICE', 'value') == 's3'
  abort 'Foreman process lacks the Active Storage bucket' unless env.dig('FOREMAN_ACTIVE_STORAGE_S3_BUCKET', 'value') == 'foreman-active-storage'
  abort 'Foreman process lacks the S3-compatible endpoint' unless env.dig('FOREMAN_ACTIVE_STORAGE_S3_ENDPOINT', 'value') == 'https://object-storage.example.test'
  abort 'Foreman process did not enable path-style S3 requests' unless env.dig('FOREMAN_ACTIVE_STORAGE_S3_FORCE_PATH_STYLE', 'value') == 'true'
  secret_name = env.dig('FOREMAN_ACTIVE_STORAGE_S3_ACCESS_KEY_ID', 'valueFrom', 'secretKeyRef', 'name')
  abort 'Foreman process lacks Secret-backed S3 credentials' unless secret_name == 'foreman-object-storage'
  abort 'Foreman process lacks the private S3 CA bundle' unless env.dig('AWS_CA_BUNDLE', 'value') == '/etc/foreman/object-storage/ca.crt'
end

preflight = s3.find do |resource|
  resource['kind'] == 'Job' && resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'dependency-preflight'
end
abort 'Foreman S3 release operation rendered no dependency preflight' unless preflight
preflight_script = preflight.fetch('spec').fetch('template').fetch('spec').fetch('containers').find do |candidate|
  candidate['name'] == 'foreman'
end.fetch('command').join("\n")
abort 'dependency preflight does not verify the Foreman bucket' unless preflight_script.include?('Aws::S3::Client') && preflight_script.include?('list_objects_v2')

policy = s3_egress.find do |resource|
  resource['kind'] == 'NetworkPolicy' && resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'foreman-egress'
end
abort 'restricted egress rendered no Foreman policy' unless policy
components = policy.dig('spec', 'podSelector', 'matchExpressions').find do |expression|
  expression['key'] == 'app.kubernetes.io/component'
end.fetch('values')
abort 'Foreman egress policy does not select the object-storage probe' unless components.include?(component)
ports = policy.dig('spec', 'egress').flat_map { |rule| Array(rule['ports']) }.map { |port| port['port'] }
abort 'Foreman object-storage egress does not permit the declared S3 port' unless ports.include?(443)

puts 'Foreman Active Storage S3 reaches every Rails role and has preflight, multipart round-trip, cleanup, CA, Secret, and egress coverage.'
