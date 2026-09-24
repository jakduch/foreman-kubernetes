#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'yaml'

root = File.expand_path('..', __dir__)
matrix = JSON.parse(File.read(File.join(root, 'compatibility/plugin-matrix.json')))
values = YAML.safe_load(File.read(File.join(root, 'charts/foreman-stack/values.yaml')))
schema = JSON.parse(File.read(File.join(root, 'charts/foreman-stack/values.schema.json')))

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

def revision(path)
  output, status = Open3.capture2('git', '-C', path, 'rev-parse', 'HEAD')
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

upstream = File.expand_path('../foreman-kubernetes-upstream', root)
if Dir.exist?(upstream)
  foreman_images = File.join(upstream, 'foreman-oci-images')
  pulp_images = File.join(upstream, 'pulp-oci-images')
  foremanctl = File.join(upstream, 'foremanctl')

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
    'foremanctlCommit' => foremanctl
  }
  expected_revisions.each do |key, path|
    raise "#{key} snapshot is stale" unless revision(path) == matrix.dig('snapshot', key)
  end
end

puts 'Plugin inventory, chart schema, and default profile agree.'
