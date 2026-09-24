#!/usr/bin/env ruby
# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'pathname'
require 'rbconfig'
require 'shellwords'
require 'time'

abort 'usage: write-integration-evidence.rb OUTPUT SET APPLICATION_PROFILE EXECUTION_PROFILE RESULT' unless ARGV.length == 5

root = Pathname.new(File.expand_path('..', __dir__))
output = Pathname.new(File.expand_path(ARGV.fetch(0)))
set_name = ARGV.fetch(1)
application_profile = Pathname.new(File.expand_path(ARGV.fetch(2)))
execution_profile = Pathname.new(File.expand_path(ARGV.fetch(3)))
result = ARGV.fetch(4)
abort "unsupported integration result: #{result}" unless %w[passed partial].include?(result)

release_sets_path = root / 'compatibility/release-sets.json'
checks_path = root / 'compatibility/required-integration-checks.json'
release_sets = JSON.parse(release_sets_path.read)
release_set = release_sets.fetch('sets').fetch(set_name)
declared_application_profile = root / release_set.fetch('applicationProfile')
declared_execution_profile = root / release_set.fetch('executionProxyProfile')

unless application_profile.realpath == declared_application_profile.realpath
  abort 'tested application profile does not match the declared compatibility set'
end
unless execution_profile.realpath == declared_execution_profile.realpath
  abort 'tested execution profile does not match the declared compatibility set'
end

checks_contract = JSON.parse(checks_path.read)
abort 'unsupported integration checks schema' unless checks_contract.fetch('schemaVersion') == 1

checks = checks_contract.fetch('checks')
checks -= ['clean-namespace-recovery'] if result == 'partial'

host_os = RbConfig::CONFIG.fetch('host_os')
operating_system = if host_os.include?('linux')
                     'linux'
                   elsif host_os.include?('darwin')
                     'darwin'
                   else
                     host_os.split(/\d/).first
                   end
architecture = `uname -m`.strip
architecture = 'amd64' if %w[amd64 x86_64].include?(architecture)
architecture = 'arm64' if %w[aarch64 arm64 arm64e].include?(architecture)
runner_platform = "#{operating_system}/#{architecture}"

git_commit = ENV['GITHUB_SHA'] || `git -C #{root.to_s.shellescape} rev-parse HEAD`.strip
abort 'integration evidence requires a full Git commit SHA' unless git_commit.match?(/\A[0-9a-f]{40}\z/)

github_actions = ENV['GITHUB_ACTIONS'] == 'true'
provenance = if github_actions
               repository = ENV.fetch('GITHUB_REPOSITORY')
               run_id = ENV.fetch('GITHUB_RUN_ID')
               run_attempt = ENV.fetch('GITHUB_RUN_ATTEMPT')
               server_url = ENV.fetch('GITHUB_SERVER_URL')
               {
                 'provider' => 'github-actions',
                 'workflow' => ENV.fetch('GITHUB_WORKFLOW'),
                 'event' => ENV.fetch('GITHUB_EVENT_NAME'),
                 'job' => ENV.fetch('GITHUB_JOB'),
                 'runId' => run_id,
                 'runAttempt' => run_attempt,
                 'runUrl' => "#{server_url}/#{repository}/actions/runs/#{run_id}"
               }
             else
               {'provider' => 'local'}
             end

evidence = {
  'schemaVersion' => 1,
  'compatibilitySet' => set_name,
  'result' => result,
  'eligibleForPromotion' => result == 'passed' &&
    runner_platform == release_set.fetch('platform') && github_actions,
  'targetPlatform' => release_set.fetch('platform'),
  'runnerPlatform' => runner_platform,
  'gitCommit' => git_commit,
  'completedAt' => Time.now.utc.iso8601,
  'provenance' => provenance,
  'inputs' => {
    'releaseSetsSha256' => Digest::SHA256.file(release_sets_path).hexdigest,
    'applicationProfileSha256' => Digest::SHA256.file(application_profile).hexdigest,
    'executionProfileSha256' => Digest::SHA256.file(execution_profile).hexdigest,
    'checksSha256' => Digest::SHA256.file(checks_path).hexdigest
  },
  'checks' => checks
}

FileUtils.mkdir_p(output.dirname)
temporary_output = Pathname.new("#{output}.tmp.#{Process.pid}")
begin
  temporary_output.write("#{JSON.pretty_generate(evidence)}\n")
  File.rename(temporary_output, output)
ensure
  temporary_output.delete if temporary_output.exist?
end

puts "Wrote #{result} integration evidence for #{set_name} to #{output}"
