#!/usr/bin/env ruby
# frozen_string_literal: true

source = File.read(File.expand_path('kind/run.sh', __dir__))

required = [
  'scripts/render-migration-stage.rb',
  '--for=condition=complete job',
  '--set releaseOperation.skipMigrationJobs=true',
  'assert_pods_unchanged',
  '.info.status == "deployed" and .version == $revision'
]
required.each do |contract|
  abort "kind release drill is missing #{contract}" unless source.include?(contract)
end

normal_path = source.match(/operation_id="kind-.*?^}/m)&.to_s
abort 'cannot identify the normal kind release path' unless normal_path
stage = normal_path.index('scripts/render-migration-stage.rb')
wait = normal_path.index('--for=condition=complete job')
rollout = normal_path.index('helm upgrade --install', stage)
unless stage && wait && rollout && stage < wait && wait < rollout
  abort 'kind release drill does not finish migrations before submitting workloads'
end

puts 'Kind release drill preserves old Pods until staged migrations succeed.'
