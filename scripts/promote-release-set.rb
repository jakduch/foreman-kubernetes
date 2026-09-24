#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'pathname'
require 'shellwords'
require 'time'

abort 'usage: promote-release-set.rb SET EVIDENCE' unless ARGV.length == 2

default_root = File.expand_path('..', __dir__)
root = Pathname.new(File.expand_path(ENV.fetch('FOREMAN_KUBERNETES_ROOT', default_root)))
set_name = ARGV.fetch(0)
evidence_path = Pathname.new(File.expand_path(ARGV.fetch(1)))
abort "invalid compatibility set name: #{set_name}" unless set_name.match?(/\A[a-z0-9][a-z0-9._-]*\z/)

release_sets_path = root / 'compatibility/release-sets.json'
checks_path = root / 'compatibility/required-integration-checks.json'
release_sets = JSON.parse(release_sets_path.read)
release_set = release_sets.fetch('sets').fetch(set_name)
evidence = JSON.parse(evidence_path.read)
required_checks = JSON.parse(checks_path.read).fetch('checks')

abort "#{set_name} is not a candidate" unless release_set.fetch('status') == 'candidate'
abort 'unsupported integration evidence schema' unless evidence.fetch('schemaVersion') == 1
abort 'integration evidence belongs to another set' unless evidence.fetch('compatibilitySet') == set_name
abort 'integration evidence is not a complete passing run' unless evidence.fetch('result') == 'passed'
abort 'integration evidence is not eligible for promotion' unless evidence.fetch('eligibleForPromotion') == true
abort 'integration target does not match the release set' unless evidence.fetch('targetPlatform') == release_set.fetch('platform')
abort 'supported sets require a native linux/amd64 run' unless evidence.fetch('runnerPlatform') == 'linux/amd64'

missing_checks = required_checks - evidence.fetch('checks')
abort "integration evidence is missing checks: #{missing_checks.join(', ')}" unless missing_checks.empty?

inputs = evidence.fetch('inputs')
expected_hashes = {
  'releaseSetsSha256' => release_sets_path,
  'applicationProfileSha256' => root / release_set.fetch('applicationProfile'),
  'executionProfileSha256' => root / release_set.fetch('executionProxyProfile'),
  'checksSha256' => checks_path
}
expected_hashes.each do |key, path|
  actual_hash = Digest::SHA256.file(path).hexdigest
  abort "integration input changed after the run: #{path.relative_path_from(root)}" unless inputs.fetch(key) == actual_hash
end

git_commit = evidence.fetch('gitCommit')
abort 'integration evidence has an invalid Git commit' unless git_commit.match?(/\A[0-9a-f]{40}\z/)
if (root / '.git').exist?
  tracked_changes = !system('git', '-C', root.to_s, 'diff', '--quiet', '--') ||
    !system('git', '-C', root.to_s, 'diff', '--cached', '--quiet', '--')
  abort 'promotion requires a clean tracked working tree' if tracked_changes
end
current_commit = ENV['GITHUB_SHA'] || `git -C #{root.to_s.shellescape} rev-parse HEAD`.strip
abort 'promotion must run from the exact tested commit' unless current_commit == git_commit

completed_at = evidence.fetch('completedAt')
abort 'integration completion time must be UTC' unless Time.iso8601(completed_at).utc.iso8601 == completed_at

provenance = evidence.fetch('provenance')
abort 'supported sets require GitHub Actions evidence' unless provenance.fetch('provider') == 'github-actions'
abort 'evidence did not come from the Full integration workflow' unless provenance.fetch('workflow') == 'Full integration'
abort 'the Full integration workflow was not manually dispatched' unless provenance.fetch('event') == 'workflow_dispatch'
abort 'evidence did not come from the integration job' unless provenance.fetch('job') == 'kind'
run_url = provenance.fetch('runUrl')
abort 'integration evidence has an invalid workflow URL' unless run_url.match?(%r{\Ahttps://github\.com/[^/]+/[^/]+/actions/runs/\d+\z})
abort 'integration evidence has an invalid workflow run ID' unless provenance.fetch('runId').match?(/\A\d+\z/)
abort 'integration evidence has an invalid workflow attempt' unless provenance.fetch('runAttempt').match?(/\A[1-9]\d*\z/)

evidence_relative_path = "compatibility/evidence/#{set_name}.json"
stored_evidence_path = root / evidence_relative_path
abort "stored evidence already exists: #{evidence_relative_path}" if stored_evidence_path.exist?

evidence_contents = "#{JSON.pretty_generate(evidence)}\n"
evidence_digest = Digest::SHA256.hexdigest(evidence_contents)
release_set['status'] = 'supported'
release_set['evidence'] = {
  'file' => evidence_relative_path,
  'sha256' => evidence_digest,
  'testedCommit' => git_commit,
  'completedAt' => completed_at,
  'workflowRun' => run_url
}

FileUtils.mkdir_p(stored_evidence_path.dirname)
evidence_temporary = Pathname.new("#{stored_evidence_path}.tmp.#{Process.pid}")
manifest_temporary = Pathname.new("#{release_sets_path}.tmp.#{Process.pid}")
evidence_installed = false
begin
  evidence_temporary.write(evidence_contents)
  manifest_temporary.write("#{JSON.pretty_generate(release_sets)}\n")
  File.rename(evidence_temporary, stored_evidence_path)
  evidence_installed = true
  File.rename(manifest_temporary, release_sets_path)
rescue StandardError
  stored_evidence_path.delete if evidence_installed && stored_evidence_path.exist?
  raise
ensure
  evidence_temporary.delete if evidence_temporary.exist?
  manifest_temporary.delete if manifest_temporary.exist?
end

puts "Promoted #{set_name} to supported with evidence from #{run_url}"
