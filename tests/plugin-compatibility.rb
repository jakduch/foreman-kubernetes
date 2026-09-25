#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'yaml'

root = File.expand_path('..', __dir__)
matrix = JSON.parse(File.read(File.join(root, 'compatibility/plugin-matrix.json')))
values = YAML.safe_load(File.read(File.join(root, 'charts/foreman-stack/values.yaml')))
schema = JSON.parse(File.read(File.join(root, 'charts/foreman-stack/values.schema.json')))
execution_values = YAML.safe_load(File.read(File.join(root, 'charts/foreman-execution-proxy/values.yaml')))
execution_deployment = File.read(File.join(root, 'charts/foreman-execution-proxy/templates/deployment.yaml'))
execution_health = File.read(File.join(root, 'charts/foreman-execution-proxy/files/check-features.rb'))
execution_control_plane = YAML.safe_load(File.read(File.join(root, 'examples/execution-control-plane-values.yaml')))

def names(entries)
  entries.map { |entry| entry.fetch('name') }.sort
end

def defaults(entries)
  entries.select { |entry| entry.fetch('enabledByDefault') }.then { |items| names(items) }
end

def image_argument(path, name)
  contents = File.read(path)
  match = contents.match(/^ARG #{Regexp.escape(name)}="([^"]+)"$/)
  raise "#{name} is missing from #{path}" unless match

  match[1].split.sort
end

def revision(path, ref = 'HEAD')
  output, status = Open3.capture2('git', '-C', path, 'rev-parse', ref)
  raise "cannot read Git revision for #{path}" unless status.success?

  output.strip
end

foreman_plugins = matrix.fetch('foreman')
pulp_plugins = matrix.fetch('pulp')

expected_foreman = names(foreman_plugins)
schema_foreman = schema.dig('properties', 'foreman', 'properties', 'enabledPlugins', 'items', 'enum').sort
raise 'Foreman plugin matrix and schema differ' unless expected_foreman == schema_foreman
raise 'Foreman plugin matrix and default values differ' unless defaults(foreman_plugins) == values.dig('foreman', 'enabledPlugins').sort

expected_pulp = names(pulp_plugins)
schema_pulp = schema.dig('properties', 'pulp', 'properties', 'enabledPlugins', 'items', 'enum').sort
raise 'Pulp plugin matrix and schema differ' unless expected_pulp == schema_pulp
raise 'Pulp plugin matrix and default values differ' unless defaults(pulp_plugins) == values.dig('pulp', 'enabledPlugins').sort

raise 'Smart Proxy must remain external to the application chart' unless values.dig('smartProxy', 'mode') == 'external'
raise 'Execution proxy must remain a singleton' unless execution_values.fetch('replicas') == 1
unless execution_deployment.include?('value: remote_execution_ssh ansible')
  raise 'Execution proxy image plugin allow-list changed'
end
unless execution_health.include?('expected = %w[ansible dynflow script]')
  raise 'Execution proxy advertised feature allow-list changed'
end
unless execution_control_plane.dig('foreman', 'enabledPlugins').sort ==
       %w[foreman-tasks foreman_ansible foreman_remote_execution katello].sort
  raise 'Execution proxy and Foreman control-plane plugin sets differ'
end
matrix.fetch('smartProxyImagePlugins').each do |plugin|
  expected_status = %w[remote_execution_ssh ansible].include?(plugin.fetch('name')) ?
    'integration-drill-implemented-unrun' : 'packaged-not-deployed'
  raise "Unexpected execution status for #{plugin.fetch('name')}" unless plugin.fetch('status') == expected_status
end

kubevirt = foreman_plugins.find { |plugin| plugin.fetch('name') == 'foreman_kubevirt' }
raise 'Foreman KubeVirt must remain integration-pending until its compatibility fix ships' unless kubevirt.fetch('status') == 'packaged-integration-pending'

kubevirt_blocker = kubevirt.fetch('blockers').find { |blocker| blocker.fetch('id') == 'dynamic-kubevirt-api-version' }
unless kubevirt_blocker&.fetch('status') == 'local-fix-prepared'
  raise 'Foreman KubeVirt API-version blocker is missing from the compatibility matrix'
end
kubevirt_network_blocker = kubevirt.fetch('blockers').find do |blocker|
  blocker.fetch('id') == 'namespaced-network-attachment-discovery'
end
unless kubevirt_network_blocker&.fetch('status') == 'local-fix-prepared'
  raise 'Foreman KubeVirt network-scope blocker is missing from the compatibility matrix'
end
kubevirt_validation_blocker = kubevirt.fetch('blockers').find do |blocker|
  blocker.fetch('id') == 'connection-validation-errors'
end
unless kubevirt_validation_blocker&.fetch('status') == 'local-fix-prepared'
  raise 'Foreman KubeVirt connection-validation blocker is missing from the compatibility matrix'
end
kubevirt_volume_blocker = kubevirt.fetch('blockers').find do |blocker|
  blocker.fetch('id') == 'partial-volume-cleanup'
end
unless kubevirt_volume_blocker&.fetch('status') == 'local-fix-prepared'
  raise 'Foreman KubeVirt partial-volume blocker is missing from the compatibility matrix'
end
kubevirt_api_body_blocker = kubevirt.fetch('blockers').find do |blocker|
  blocker.fetch('id') == 'grouped-vm-api-version'
end
unless kubevirt_api_body_blocker&.fetch('status') == 'local-fix-prepared'
  raise 'Fog KubeVirt VM API-version blocker is missing from the compatibility matrix'
end

upstream = File.expand_path('../foreman-kubernetes-upstream', root)
if Dir.exist?(upstream)
  foreman_images = File.join(upstream, 'foreman-oci-images')
  pulp_images = File.join(upstream, 'pulp-oci-images')
  foremanctl = File.join(upstream, 'foremanctl')
  foreman_webhooks = File.join(upstream, 'foreman_webhooks')
  foreman_virt_who_configure = File.join(upstream, 'foreman_virt_who_configure')
  foreman_kubevirt = File.join(upstream, 'foreman_kubevirt')
  fog_kubevirt = File.join(upstream, 'fog-kubevirt')

  foreman_containerfile = File.join(foreman_images, 'images/foreman/Containerfile')
  proxy_containerfile = File.join(foreman_images, 'images/foreman-proxy/Containerfile')
  pulp_containerfile = File.join(pulp_images, 'images/pulp/Containerfile')

  raise 'Foreman OCI image plugin inventory changed' unless image_argument(foreman_containerfile, 'FOREMAN_PLUGINS') == expected_foreman
  raise 'Smart Proxy OCI image plugin inventory changed' unless image_argument(proxy_containerfile, 'FOREMAN_PROXY_PLUGINS') == names(matrix.fetch('smartProxyImagePlugins'))

  pulp_package_match = File.read(pulp_containerfile).match(/pulpcore-plugin\\\(\{([^}]+)\}\\\)/)
  raise 'Pulp OCI plugin package inventory is unreadable' unless pulp_package_match

  image_pulp = pulp_package_match[1].split(',').map { |plugin| "pulp_#{plugin}" }
  image_pulp.concat(%w[pulp_certguard pulp_file])
  raise 'Pulp OCI image plugin inventory changed' unless image_pulp.sort == expected_pulp

  expected_revisions = {
    'foremanOciImagesCommit' => foreman_images,
    'pulpOciImagesCommit' => pulp_images,
    'foremanctlCommit' => foremanctl,
    'foremanWebhooksCommit' => foreman_webhooks,
    'foremanVirtWhoConfigureCommit' => foreman_virt_who_configure,
    'foremanKubevirtDocumentationPatchCommit' => foreman_kubevirt,
    'fogKubevirtApiVersionPatchCommit' => fog_kubevirt
  }
  expected_revisions.each do |key, path|
    raise "#{key} snapshot is stale" unless revision(path) == matrix.dig('snapshot', key)
  end
  unless revision(foreman_kubevirt, 'HEAD^') == matrix.dig('snapshot', 'foremanKubevirtVolumePatchCommit')
    raise 'foremanKubevirtVolumePatchCommit snapshot is stale'
  end
  unless revision(foreman_kubevirt, 'HEAD^^') == matrix.dig('snapshot', 'foremanKubevirtValidationPatchCommit')
    raise 'foremanKubevirtValidationPatchCommit snapshot is stale'
  end
  unless revision(foreman_kubevirt, 'HEAD^^^') == matrix.dig('snapshot', 'foremanKubevirtCompatibilityPatchCommit')
    raise 'foremanKubevirtCompatibilityPatchCommit snapshot is stale'
  end
  unless revision(foreman_kubevirt, 'HEAD^^^^') == matrix.dig('snapshot', 'foremanKubevirtUpstreamCommit')
    raise 'foremanKubevirtUpstreamCommit snapshot is stale'
  end
  unless revision(fog_kubevirt, 'HEAD^') == matrix.dig('snapshot', 'fogKubevirtNamespacePatchCommit')
    raise 'fogKubevirtNamespacePatchCommit snapshot is stale'
  end
  unless revision(fog_kubevirt, 'HEAD^^') == matrix.dig('snapshot', 'fogKubevirtUpstreamCommit')
    raise 'fogKubevirtUpstreamCommit snapshot is stale'
  end
end

puts 'Plugin inventory, chart schema, and default profile agree.'
