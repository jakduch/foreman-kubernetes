#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST" unless ARGV.length == 1

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
deployment = documents.find { |item| item['kind'] == 'Deployment' }
abort 'operator Deployment is missing' unless deployment
abort 'operator does not publish a warm standby' unless deployment.dig('spec', 'replicas') == 2
abort 'operator cannot roll between elected leaders' unless deployment.dig('spec', 'strategy', 'type') == 'RollingUpdate'
abort 'operator rollout can remove every candidate' unless deployment.dig('spec', 'strategy', 'rollingUpdate', 'maxUnavailable') == 1
abort 'operator requires its Kubernetes API token' unless deployment.dig('spec', 'template', 'spec', 'automountServiceAccountToken') == true
environment = Array(deployment.dig('spec', 'template', 'spec', 'containers', 0, 'env'))
pod_uid = environment.find { |entry| entry['name'] == 'POD_UID' }
abort 'operator leader identity is not sourced from the Pod UID' unless pod_uid&.dig('valueFrom', 'fieldRef', 'fieldPath') == 'metadata.uid'
abort 'operator has no leader Lease name' unless environment.any? { |entry| entry['name'] == 'LEADER_LEASE_NAME' }
abort 'operator has no leader Lease duration' unless environment.any? { |entry| entry['name'] == 'LEADER_LEASE_DURATION_SECONDS' }

pdb = documents.find { |item| item['kind'] == 'PodDisruptionBudget' }
abort 'operator PodDisruptionBudget is missing' unless pdb
abort 'operator disruption budget can evict every candidate' unless pdb.dig('spec', 'maxUnavailable') == 1

role = documents.find { |item| item['kind'] == 'Role' }
abort 'operator namespaced Role is missing' unless role
resources = Array(role['rules']).flat_map { |rule| Array(rule['resources']) }
%w[foremanreleases foremanreleases/status leases jobs deployments secrets].each do |required|
  abort "operator Role is missing #{required}" unless resources.include?(required)
end
%w[nodes namespaces persistentvolumes].each do |forbidden|
  abort "operator Role unexpectedly grants #{forbidden}" if resources.include?(forbidden)
end
edge_resources = %w[dhcp dns tftp smartproxies]
abort 'operator Role grants an edge Smart Proxy capability' unless (resources & edge_resources).empty?

cluster_role = documents.find { |item| item['kind'] == 'ClusterRole' }
abort 'operator cluster preflight role is missing' unless cluster_role
cluster_rules = Array(cluster_role['rules'])
cluster_resources = cluster_rules.flat_map { |rule| Array(rule['resources']) }.sort
expected_cluster_resources = %w[apiservices ingressclasses storageclasses]
abort "unexpected cluster-scoped resources: #{cluster_resources.join(', ')}" unless cluster_resources == expected_cluster_resources
cluster_verbs = cluster_rules.flat_map { |rule| Array(rule['verbs']) }.uniq.sort
abort 'cluster preflight permissions are not read-only' unless cluster_verbs == %w[get list]

puts 'Release operator elects one leader with bounded namespace and read-only cluster RBAC.'
