#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'open3'
require 'tmpdir'
require 'yaml'

root = File.expand_path('..', __dir__)
values = YAML.safe_load(File.read(File.join(root, 'tests/kind/values.yaml')), aliases: true)
plugins = values.dig('pulp', 'enabledPlugins')
abort 'kind integration profile does not enable pulp_container' unless plugins.include?('pulp_container')

config_json = '{"architecture":"amd64","config":{},"os":"linux","rootfs":{"diff_ids":[],"type":"layers"}}'
config_digest = '067c4dd72da4d166811c210f3d96a24e0f1c7ed7f02f905f6f78e03d500f7c59'
manifest_json = '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","size":90,"digest":"sha256:067c4dd72da4d166811c210f3d96a24e0f1c7ed7f02f905f6f78e03d500f7c59"},"layers":[]}'
manifest_digest = 'ee2cdbe59e4f2fd7d147f75965389f494b67b1b33107f3b8d487eef5f41b1f36'
tag_json = '{"name":"foreman-kubernetes-fixture","tags":["1.0.0"]}'

dependencies = YAML.load_stream(File.read(File.join(root, 'tests/kind/dependencies.yaml'))).compact
fixture = dependencies.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name') == 'content-source'
end
abort 'kind integration dependencies have no content-source fixture' unless fixture

data = fixture.fetch('data')
abort 'content source has no OCI config fixture' unless data['oci-config.json'] == config_json
abort 'content source has no OCI manifest fixture' unless data['oci-manifest.json'] == manifest_json
abort 'content source has no OCI tag fixture' unless data['oci-tags.json'] == tag_json
abort 'OCI config fixture has the wrong size' unless config_json.bytesize == 90
abort 'OCI config fixture has the wrong checksum' unless Digest::SHA256.hexdigest(config_json) == config_digest
abort 'OCI manifest fixture has the wrong size' unless manifest_json.bytesize == 247
abort 'OCI manifest fixture has the wrong checksum' unless Digest::SHA256.hexdigest(manifest_json) == manifest_digest
JSON.parse(config_json)
JSON.parse(manifest_json)
JSON.parse(tag_json)

nginx = data.fetch('nginx.conf')
%w[
  Docker-Distribution-Api-Version
  Docker-Content-Digest
  application/vnd.oci.image.manifest.v1+json
  application/vnd.oci.image.config.v1+json
  /v2/
  /manifests/
  /blobs/
  /tags/list
].each do |contract|
  abort "OCI content source Nginx configuration is missing #{contract}" unless nginx.include?(contract)
end

deployment = dependencies.find do |resource|
  resource['kind'] == 'Deployment' && resource.dig('metadata', 'name') == 'content-source'
end
abort 'kind integration dependencies have no content-source Deployment' unless deployment
builder = deployment.dig('spec', 'template', 'spec', 'initContainers')&.find do |container|
  container['name'] == 'build-content-source'
end
abort 'content source has no OCI repository builder' unless builder
builder_script = builder.fetch('command').last
%w[oci-config.json oci-manifest.json oci-tags.json /v2/ manifests blobs tags/list].each do |contract|
  abort "OCI repository builder is missing #{contract}" unless builder_script.include?(contract)
end

Dir.mktmpdir('foreman-kubernetes-container-source') do |directory|
  source = File.join(directory, 'source')
  served = File.join(directory, 'served')
  temporary = File.join(directory, 'tmp')
  FileUtils.mkdir_p([source, served, temporary])
  data.each { |name, contents| File.binwrite(File.join(source, name), contents) }
  fixture.fetch('binaryData', {}).each do |name, contents|
    File.binwrite(File.join(source, name), Base64.strict_decode64(contents))
  end

  test_script = builder_script.gsub('/source', source).gsub('/served', served)
  _stdout, stderr, status = Open3.capture3({'TMPDIR' => temporary}, '/bin/sh', '-ec', test_script)
  abort "OCI fixture builder failed: #{stderr}" unless status.success?

  manifest = File.join(served, 'v2/foreman-kubernetes-fixture/manifests/1.0.0')
  manifest_by_digest = File.join(served, 'v2/foreman-kubernetes-fixture/manifests/sha256:ee2cdbe59e4f2fd7d147f75965389f494b67b1b33107f3b8d487eef5f41b1f36')
  config = File.join(served, 'v2/foreman-kubernetes-fixture/blobs/sha256:067c4dd72da4d166811c210f3d96a24e0f1c7ed7f02f905f6f78e03d500f7c59')
  tags = File.join(served, 'v2/foreman-kubernetes-fixture/tags/list')
  [manifest, manifest_by_digest, config, tags].each do |path|
    abort "OCI fixture builder did not create #{path}" unless File.file?(path)
  end
  abort 'served OCI manifest has the wrong checksum' unless Digest::SHA256.file(manifest).hexdigest == manifest_digest
  abort 'served OCI digest manifest has the wrong checksum' unless Digest::SHA256.file(manifest_by_digest).hexdigest == manifest_digest
  abort 'served OCI config has the wrong checksum' unless Digest::SHA256.file(config).hexdigest == config_digest
  abort 'served OCI tag list differs from the fixture' unless File.read(tags) == tag_json
end

lifecycle = File.read(File.join(root, 'tests/kind/content-lifecycle.sh'))
required_lifecycle_contracts = [
  'content_type: "docker"',
  'docker_upstream_name',
  '/docker_tags?per_page=all',
  '/docker_manifests?per_page=all',
  'published container tag manifest digest',
  'published_container_repository_id',
  'restored library container'
]
required_lifecycle_contracts.each do |contract|
  abort "kind content lifecycle is missing #{contract}" unless lifecycle.include?(contract)
end

checks = JSON.parse(File.read(File.join(root, 'compatibility/required-integration-checks.json'))).fetch('checks')
abort 'promotion evidence does not require the container content lifecycle' unless checks.include?('pulp-container-lifecycle')

matrix = JSON.parse(File.read(File.join(root, 'compatibility/plugin-matrix.json')))
container = matrix.fetch('pulp').find { |plugin| plugin.fetch('name') == 'pulp_container' }
unless container.fetch('status') == 'integration-drill-implemented-unrun'
  abort 'Pulp container compatibility status does not reflect the implemented drill'
end

puts 'Kind integration covers OCI container synchronization, publication, registry delivery, and restore.'
