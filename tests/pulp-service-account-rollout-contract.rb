#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

def documents(path)
  YAML.load_stream(File.read(path)).compact
end

def pulp_deployments(path)
  documents(path).select do |document|
    document['kind'] == 'Deployment' &&
      %w[pulp-api pulp-content pulp-worker].include?(
        document.dig('spec', 'template', 'metadata', 'labels', 'app.kubernetes.io/component')
      )
  end
end

default_path, identity_path = ARGV
abort 'usage: pulp-service-account-rollout-contract.rb DEFAULT_RENDER IDENTITY_RENDER' unless identity_path

default_deployments = pulp_deployments(default_path)
identity_deployments = pulp_deployments(identity_path)

abort 'expected all three Pulp runtime Deployments in both renders' unless
  default_deployments.length == 3 && identity_deployments.length == 3

default_checksums = default_deployments.to_h do |deployment|
  [
    deployment.dig('spec', 'template', 'metadata', 'labels', 'app.kubernetes.io/component'),
    deployment.dig('spec', 'template', 'metadata', 'annotations', 'checksum/service-account'),
  ]
end
identity_checksums = identity_deployments.to_h do |deployment|
  [
    deployment.dig('spec', 'template', 'metadata', 'labels', 'app.kubernetes.io/component'),
    deployment.dig('spec', 'template', 'metadata', 'annotations', 'checksum/service-account'),
  ]
end

abort 'Pulp ServiceAccount checksums must be present' if
  default_checksums.values.any? { |checksum| checksum.nil? || checksum.empty? } ||
  identity_checksums.values.any? { |checksum| checksum.nil? || checksum.empty? }

unchanged = default_checksums.keys.select do |component|
  default_checksums.fetch(component) == identity_checksums.fetch(component)
end
abort "workload identity did not roll: #{unchanged.join(', ')}" unless unchanged.empty?

service_account = documents(identity_path).find do |document|
  document['kind'] == 'ServiceAccount' && document.dig('metadata', 'name') == 'test-foreman-stack-pulp'
end
abort 'missing chart-managed Pulp ServiceAccount' unless service_account

expected_role = 'arn:aws:iam::123456789012:role/foreman-pulp'
actual_role = service_account.dig('metadata', 'annotations', 'eks.amazonaws.com/role-arn')
abort "unexpected Pulp workload identity role: #{actual_role.inspect}" unless actual_role == expected_role

puts 'Pulp workload identity rollout contract passed'
