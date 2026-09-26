#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'pathname'
require 'rbconfig'
require 'tmpdir'

root = Pathname.new(File.expand_path('..', __dir__))
release_sets = JSON.parse((root / 'compatibility/release-sets.json').read)
set_name = release_sets.fetch('default')
release_set = release_sets.fetch('sets').fetch(set_name)
verifier = root / 'scripts/verify-release-image-platforms.rb'
application_profile = root / release_set.fetch('applicationProfile')
execution_profile = root / release_set.fetch('executionProxyProfile')

Dir.mktmpdir('foreman-image-platforms') do |directory|
  work = Pathname.new(directory)
  inspector = work / 'image-inspector'
  inspector.write(<<~RUBY)
    #!#{RbConfig.ruby}
    puts ENV.fetch('FAKE_IMAGE_PLATFORM')
  RUBY
  inspector.chmod(0o755)

  output = work / 'platforms.json'
  environment = {
    'IMAGE_INSPECTOR' => inspector.to_s,
    'FAKE_IMAGE_PLATFORM' => release_set.fetch('platform')
  }
  stdout, stderr, status = Open3.capture3(
    environment,
    RbConfig.ruby,
    verifier.to_s,
    output.to_s,
    set_name,
    application_profile.to_s,
    execution_profile.to_s
  )
  abort stderr unless status.success?
  abort 'image verifier did not report success' unless stdout.include?('Verified 4 image manifests')

  report = JSON.parse(output.read)
  abort 'image report belongs to another set' unless report.fetch('compatibilitySet') == set_name
  unless report.fetch('expectedPlatform') == release_set.fetch('platform')
    abort 'image report has the wrong expected platform'
  end
  components = report.fetch('images').map { |image| image.fetch('component') }.sort
  unless components == %w[candlepin execution-proxy foreman pulp]
    abort 'image report does not cover all runtime components'
  end
  unless report.fetch('images').all? { |image| image.fetch('reference').match?(/@sha256:[0-9a-f]{64}\z/) }
    abort 'image report contains a mutable reference'
  end

  mismatched_platform = release_set.fetch('platform') == 'linux/amd64' ? 'linux/arm64' : 'linux/amd64'
  _stdout, stderr, status = Open3.capture3(
    environment.merge('FAKE_IMAGE_PLATFORM' => mismatched_platform),
    RbConfig.ruby,
    verifier.to_s,
    (work / 'mismatch.json').to_s,
    set_name,
    application_profile.to_s,
    execution_profile.to_s
  )
  abort 'image verifier accepted a manifest for another platform' if status.success?
  expected_message = "expected #{release_set.fetch('platform')}"
  abort 'image platform mismatch was not explicit' unless stderr.include?(expected_message)
end

puts 'Release image platform verification is digest-pinned and architecture-specific.'
