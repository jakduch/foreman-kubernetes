#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

abort "usage: #{$PROGRAM_NAME} RELEASE_NAME RELEASE_NAMESPACE" unless ARGV.length == 2

release_name, release_namespace = ARGV
components = %w[candlepin-migrate pulp-migrate foreman-migrate].freeze
dependency_kinds = %w[ConfigMap PersistentVolumeClaim ServiceAccount].freeze
documents = YAML.load_stream($stdin.read).compact
migrations = documents.select do |item|
  item['kind'] == 'Job' && components.include?(item.dig('metadata', 'labels', 'app.kubernetes.io/component'))
end
abort 'rendered application must contain exactly three migration Jobs' unless migrations.length == 3

references = dependency_kinds.to_h { |kind| [kind, []] }
migrations.each do |job|
  pod_spec = job.dig('spec', 'template', 'spec') || {}
  references['ServiceAccount'] << pod_spec['serviceAccountName'] if pod_spec['serviceAccountName']
  Array(pod_spec['volumes']).each do |volume|
    references['ConfigMap'] << volume.dig('configMap', 'name') if volume.dig('configMap', 'name')
    claim = volume.dig('persistentVolumeClaim', 'claimName')
    references['PersistentVolumeClaim'] << claim if claim
  end
end
references.each_value(&:uniq!)

dependencies = documents.select do |item|
  references.fetch(item['kind'], []).include?(item.dig('metadata', 'name'))
end
references.each do |kind, names|
  present = dependencies.select { |item| item['kind'] == kind }.map { |item| item.dig('metadata', 'name') }
  missing = names - present
  abort "migration render is missing #{kind}: #{missing.join(', ')}" unless missing.empty?
end

dependencies.each do |dependency|
  metadata = dependency.fetch('metadata')
  metadata['labels'] ||= {}
  metadata['labels']['app.kubernetes.io/managed-by'] = 'Helm'
  metadata['annotations'] ||= {}
  metadata['annotations']['meta.helm.sh/release-name'] = release_name
  metadata['annotations']['meta.helm.sh/release-namespace'] = release_namespace
end

migrations.each do |job|
  metadata = job.fetch('metadata')
  metadata['labels'] ||= {}
  metadata['labels']['app.kubernetes.io/managed-by'] = 'foreman-release-script'
  metadata.fetch('annotations', {}).delete_if { |key, _value| key.start_with?('helm.sh/hook') }
  job.fetch('spec')['ttlSecondsAfterFinished'] = 3600
end

puts (dependencies + migrations).map { |document| YAML.dump(document) }.join
