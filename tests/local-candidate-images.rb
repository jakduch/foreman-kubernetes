#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'yaml'

root = Pathname.new(File.expand_path('..', __dir__))
registry = JSON.parse((root / 'compatibility/local-candidate-images.json').read)
contracts = JSON.parse((root / 'compatibility/upstream-contracts.json').read)
  .fetch('contracts').to_h { |contract| [contract.fetch('id'), contract] }
profile = YAML.safe_load((root / 'profiles/local-amd64-candidate.yaml').read)
release_profile = YAML.safe_load((root / 'profiles/nightly-candidate-2026-09-23.yaml').read)

abort 'unsupported local candidate schema' unless registry.fetch('schemaVersion') == 1
abort 'local candidate pipeline must be native amd64' unless registry.fetch('platform') == 'linux/amd64'
abort 'local candidate pipeline must cover every application image' unless registry.fetch('images').keys.sort == %w[candlepin foreman pulp]

seen_contracts = []
registry.fetch('images').each do |component, image|
  base = image.fetch('baseReference')
  abort "#{component} local candidate base is not digest-pinned" unless base.match?(/@sha256:[0-9a-f]{64}\z/)
  expected_base = "#{release_profile.fetch(component).fetch('image').fetch('repository')}:#{release_profile.fetch(component).fetch('image').fetch('tag')}"
  abort "#{component} local candidate base differs from the release profile" unless base == expected_base

  local = image.fetch('localReference')
  local_image = profile.fetch(component).fetch('image')
  expected_local = "#{local_image.fetch('repository')}:#{local_image.fetch('tag')}"
  abort "#{component} profile differs from the build registry" unless local == expected_local
  abort "#{component} local candidate must not pull from a registry" unless local_image.fetch('pullPolicy') == 'Never'

  overlays = Array(image['overlays'])
  ids = overlays.map { |overlay| overlay.fetch('contract') } + Array(image['contracts'])
  ids.each do |id|
    contract = contracts.fetch(id) { abort "unknown local candidate contract: #{id}" }
    abort "published contract is unexpectedly overlaid: #{id}" if contract.fetch('state') == 'published'
    seen_contracts << id
  end
  overlays.each do |overlay|
    abort 'unsupported overlay target' unless %w[foreman katello candlepin].include?(overlay.fetch('target'))
    overlay.fetch('paths').each do |source_path|
      path = Pathname.new(source_path)
      abort "unsafe overlay path: #{source_path}" if path.absolute? || path.each_filename.include?('..')
      abort "test-only path leaked into a runtime image: #{source_path}" if source_path.start_with?('test/', 'tests/', '.github/')
    end
  end
end

abort 'local candidate contracts are duplicated' unless seen_contracts == seen_contracts.uniq
required = contracts.values.select { |contract| !(contract.fetch('profiles') & %w[default object-storage]).empty? }
  .map { |contract| contract.fetch('id') }
missing = required - seen_contracts
abort "local candidate pipeline omits required contracts: #{missing.join(', ')}" unless missing.empty?

node_selector = profile.dig('scheduling', 'nodeSelector')
abort 'local candidate profile does not require amd64 nodes' unless node_selector == {'kubernetes.io/arch' => 'amd64'}

puts "Local candidate images cover #{seen_contracts.length} unpublished runtime contracts."
