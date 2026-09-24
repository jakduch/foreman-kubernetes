#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
dockerfile = (root / 'images/recovery-toolbox/Dockerfile').read
workflow = (root / '.github/workflows/recovery-image.yaml').read

unless dockerfile.match?(/^FROM alpine:3\.23\.6@sha256:[0-9a-f]{64}$/)
  abort 'recovery toolbox base image is not pinned to the reviewed Alpine manifest'
end

%w[ca-certificates jq kubectl postgresql18-client restic].each do |package|
  abort "recovery toolbox is missing #{package}" unless dockerfile.match?(/^\s+#{Regexp.escape(package)}(?:\s|\\|$)/)
end

abort 'recovery image workflow cannot publish packages' unless workflow.include?('packages: write')
abort 'recovery image workflow is not restricted to linux/amd64' unless workflow.include?('platforms: linux/amd64')
abort 'recovery image workflow does not emit provenance' unless workflow.include?('provenance: mode=max')
abort 'recovery image workflow does not emit an SBOM' unless workflow.include?('sbom: true')
abort 'recovery image workflow does not report the immutable digest' unless workflow.include?('steps.publish.outputs.digest')

%w[cmp jq kubectl pg_dump pg_restore restic sha256sum].each do |command|
  abort "recovery image workflow does not verify #{command}" unless workflow.include?(command)
end

puts 'Recovery toolbox build and publication contract passed.'
