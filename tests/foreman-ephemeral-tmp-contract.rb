#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

unless ARGV.length == 2 && %w[true false].include?(ARGV.fetch(1))
  abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST EXPECT_PULP_CLAIM(true|false)"
end

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
expect_pulp_claim = ARGV.fetch(1) == 'true'

def pod_template(resource)
  case resource['kind']
  when 'CronJob'
    resource.dig('spec', 'jobTemplate', 'spec', 'template')
  when 'Deployment', 'StatefulSet', 'DaemonSet', 'Job', 'Pod'
    resource.dig('spec', 'template') || resource
  end
end

claims = documents.select { |resource| resource['kind'] == 'PersistentVolumeClaim' }
claim_components = claims.to_h do |claim|
  [claim.dig('metadata', 'labels', 'app.kubernetes.io/component'), claim]
end

%w[foreman-tmp foreman-avatars].each do |component|
  abort "#{component} must not be rendered as a persistent claim" if claim_components.key?(component)
end

pulp_claim_present = claim_components.key?('pulp')
abort "Pulp claim expectation differs: expected #{expect_pulp_claim}, got #{pulp_claim_present}" unless
  pulp_claim_present == expect_pulp_claim

checked = []
documents.each do |resource|
  template = pod_template(resource)
  next unless template

  pod_spec = template.fetch('spec')
  volumes = Array(pod_spec['volumes']).to_h { |volume| [volume['name'], volume] }
  abort "#{resource.dig('metadata', 'name')} still defines a Foreman avatar volume" if volumes.key?('foreman-avatars')

  containers = Array(pod_spec['initContainers']) + Array(pod_spec['containers'])
  containers.each do |container|
    mounts = Array(container['volumeMounts'])
    if mounts.any? { |mount| mount['name'] == 'foreman-avatars' || mount['mountPath'] == '/usr/share/foreman/public/images/avatars' }
      abort "#{resource.dig('metadata', 'name')}/#{container['name']} still mounts Foreman avatars"
    end

    foreman_process = Array(container['env']).any? { |item| item['name'] == 'FOREMAN_ENABLED_PLUGINS' }
    next unless foreman_process

    mount = mounts.find { |item| item['mountPath'] == '/usr/share/foreman/tmp' }
    abort "#{resource.dig('metadata', 'name')}/#{container['name']} lacks per-Pod Foreman tmp" unless mount

    volume = volumes[mount['name']]
    unless volume&.dig('emptyDir', 'sizeLimit') == '20Gi' && !volume.key?('persistentVolumeClaim')
      abort "#{resource.dig('metadata', 'name')}/#{container['name']} does not use bounded emptyDir tmp"
    end

    checked << [resource.dig('metadata', 'name'), container['name']]
  end
end

abort 'no Foreman-derived processes were checked' if checked.empty?

config = documents.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name').to_s.end_with?('-foreman-config')
end
abort 'chart still injects an event daemon implementation' if config&.dig('data')&.key?('katello-event-daemon.rb')

puts "Bounded per-Pod Foreman tmp covers #{checked.length} rendered process containers; no avatar PVC remains."
