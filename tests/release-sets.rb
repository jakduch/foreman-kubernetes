#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'
require 'yaml'

root = Pathname.new(File.expand_path('..', __dir__))
manifest = JSON.parse((root / 'compatibility/release-sets.json').read)
sets = manifest.fetch('sets')
default_set = manifest.fetch('default')

raise 'unsupported release-set schema' unless manifest.fetch('schemaVersion') == 1
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
  raise "unsupported status for #{set_name}" unless %w[candidate supported retired].include?(release_set.fetch('status'))
  raise "unsupported platform for #{set_name}" unless release_set.fetch('platform') == 'linux/amd64'

  application_profile = YAML.safe_load(profile_path(root, release_set.fetch('applicationProfile')).read)
  execution_profile = YAML.safe_load(profile_path(root, release_set.fetch('executionProxyProfile')).read)

  %w[foreman candlepin pulp].each do |component|
    digest_pinned!(set_name, component, application_profile.fetch(component).fetch('image'))
  end
  digest_pinned!(set_name, 'execution proxy', execution_profile.fetch('image'))
end

puts "Validated #{sets.length} digest-pinned release set(s); default is #{default_set}."
