#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'json'
require 'pathname'
require 'time'
require 'yaml'

default_root = File.expand_path('..', __dir__)
root = Pathname.new(File.expand_path(ENV.fetch('FOREMAN_KUBERNETES_ROOT', default_root)))
manifest = JSON.parse((root / 'compatibility/release-sets.json').read)
sets = manifest.fetch('sets')
default_set = manifest.fetch('default')
checks_path = root / 'compatibility/required-integration-checks.json'
checks_contract = JSON.parse(checks_path.read)
required_checks = checks_contract.fetch('checks')

raise 'unsupported release-set schema' unless manifest.fetch('schemaVersion') == 1
raise 'unsupported integration checks schema' unless checks_contract.fetch('schemaVersion') == 1
raise 'integration checks must be unique non-empty strings' unless required_checks == required_checks.uniq && required_checks.all? { |check| check.is_a?(String) && !check.empty? }
raise "default release set #{default_set} does not exist" unless sets.key?(default_set)

def profile_path(root, relative_path)
  path = root.join(relative_path).cleanpath
  raise "profile escapes the repository: #{relative_path}" unless path.to_s.start_with?("#{root}/")
  raise "profile does not exist: #{relative_path}" unless path.file?

  path
end

def digest_pinned!(set_name, component, image)
  reference = "#{image.fetch('repository')}:#{image.fetch('tag')}"
  return if reference.match?(/@sha256:[0-9a-f]{64}\z/)

  raise "#{set_name} #{component} image is not digest-pinned: #{reference}"
end

sets.each do |set_name, release_set|
  status = release_set.fetch('status')
  raise "unsupported status for #{set_name}" unless %w[candidate supported retired].include?(status)
  raise "unsupported platform for #{set_name}" unless release_set.fetch('platform') == 'linux/amd64'

  application_profile_path = profile_path(root, release_set.fetch('applicationProfile'))
  execution_profile_path = profile_path(root, release_set.fetch('executionProxyProfile'))
  application_profile = YAML.safe_load(application_profile_path.read)
  execution_profile = YAML.safe_load(execution_profile_path.read)

  %w[foreman candlepin pulp].each do |component|
    digest_pinned!(set_name, component, application_profile.fetch(component).fetch('image'))
  end
  digest_pinned!(set_name, 'execution proxy', execution_profile.fetch('image'))

  if status == 'candidate' && release_set.key?('evidence')
    raise "candidate #{set_name} must not carry supported evidence"
  end
  next unless status == 'supported'

  evidence_reference = release_set.fetch('evidence')
  evidence_path = profile_path(root, evidence_reference.fetch('file'))
  evidence_digest = Digest::SHA256.file(evidence_path).hexdigest
  raise "stored evidence digest mismatch for #{set_name}" unless evidence_reference.fetch('sha256') == evidence_digest

  evidence = JSON.parse(evidence_path.read)
  raise "unsupported evidence schema for #{set_name}" unless evidence.fetch('schemaVersion') == 1
  raise "stored evidence belongs to another set: #{set_name}" unless evidence.fetch('compatibilitySet') == set_name
  raise "stored evidence did not pass for #{set_name}" unless evidence.fetch('result') == 'passed' && evidence.fetch('eligibleForPromotion') == true
  raise "stored evidence used another target for #{set_name}" unless evidence.fetch('targetPlatform') == release_set.fetch('platform')
  raise "stored evidence did not run natively for #{set_name}" unless evidence.fetch('runnerPlatform') == 'linux/amd64'
  raise "stored evidence commit mismatch for #{set_name}" unless evidence_reference.fetch('testedCommit') == evidence.fetch('gitCommit')
  raise "stored evidence timestamp mismatch for #{set_name}" unless evidence_reference.fetch('completedAt') == evidence.fetch('completedAt')
  raise "stored evidence workflow mismatch for #{set_name}" unless evidence_reference.fetch('workflowRun') == evidence.dig('provenance', 'runUrl')
  raise "invalid stored evidence commit for #{set_name}" unless evidence.fetch('gitCommit').match?(/\A[0-9a-f]{40}\z/)
  raise "invalid stored evidence timestamp for #{set_name}" unless Time.iso8601(evidence.fetch('completedAt')).utc.iso8601 == evidence.fetch('completedAt')

  provenance = evidence.fetch('provenance')
  raise "unsupported evidence provider for #{set_name}" unless provenance.fetch('provider') == 'github-actions'
  raise "unexpected evidence workflow for #{set_name}" unless provenance.fetch('workflow') == 'Full integration'
  raise "unexpected evidence event for #{set_name}" unless provenance.fetch('event') == 'workflow_dispatch'
  raise "unexpected evidence job for #{set_name}" unless provenance.fetch('job') == 'kind'
  raise "invalid evidence workflow URL for #{set_name}" unless provenance.fetch('runUrl').match?(%r{\Ahttps://github\.com/[^/]+/[^/]+/actions/runs/\d+\z})

  missing_checks = required_checks - evidence.fetch('checks')
  raise "stored evidence is missing checks for #{set_name}: #{missing_checks.join(', ')}" unless missing_checks.empty?

  evidence_inputs = evidence.fetch('inputs')
  expected_inputs = {
    'applicationProfileSha256' => Digest::SHA256.file(application_profile_path).hexdigest,
    'executionProfileSha256' => Digest::SHA256.file(execution_profile_path).hexdigest,
    'checksSha256' => Digest::SHA256.file(checks_path).hexdigest
  }
  expected_inputs.each do |key, expected_digest|
    raise "stored evidence input mismatch for #{set_name}: #{key}" unless evidence_inputs.fetch(key) == expected_digest
  end
end

puts "Validated #{sets.length} digest-pinned release set(s); default is #{default_set}."
