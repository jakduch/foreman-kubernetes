#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

unless ARGV.length == 2 && %w[true false].include?(ARGV.fetch(1))
  abort "usage: #{$PROGRAM_NAME} RENDERED_MANIFEST EXPECT_PULP_FILESYSTEM(true|false)"
end

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
expect_pulp = ARGV.fetch(1) == 'true'

job = documents.find do |resource|
  resource['kind'] == 'Job' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component').to_s.start_with?('recovery-')
end
abort 'recovery Job is missing' unless job

pod_spec = job.dig('spec', 'template', 'spec')
container = Array(pod_spec&.fetch('containers', nil)).first
volumes = Array(pod_spec&.fetch('volumes', nil)).to_h { |volume| [volume['name'], volume] }
mounts = Array(container&.fetch('volumeMounts', nil)).to_h { |mount| [mount['name'], mount] }

avatar_mount = mounts['foreman-avatars']
avatar_volume = volumes['foreman-avatars']
abort 'recovery Job does not mount Foreman avatars' unless avatar_mount&.fetch('mountPath', nil) == '/var/lib/foreman/avatars'
abort 'Foreman avatar recovery volume is not a PVC' unless avatar_volume&.dig('persistentVolumeClaim', 'claimName')

pulp_mounted = mounts.key?('pulp-data') && volumes.dig('pulp-data', 'persistentVolumeClaim', 'claimName')
abort "Pulp recovery volume expectation differs: expected #{expect_pulp}, got #{!!pulp_mounted}" unless !!pulp_mounted == expect_pulp

scripts = documents.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name').to_s.end_with?('-recovery-scripts')
end
backup = scripts&.dig('data', 'backup.sh').to_s
restore = scripts&.dig('data', 'restore.sh').to_s
common = scripts&.dig('data', 'recovery-common.sh').to_s

abort 'backup manifest does not record Foreman avatars' unless backup.include?('includes_foreman_avatars: true')
abort 'backup does not include Foreman avatars' unless backup.include?('set -- /work /var/lib/foreman/avatars')
abort 'restore does not require the avatar-aware schema' unless restore.include?('.schema_version == "2"')
abort 'restore does not replace Foreman avatars' unless restore.include?("--include '/var/lib/foreman/avatars/**'")
abort 'restore does not inspect snapshot contents' unless restore.include?('restic ls --json')
validation_boundary = restore.index('Snapshot validation completed; starting destructive restore')
avatar_deletion = restore.index('find /var/lib/foreman/avatars')
pulp_deletion = restore.index('find /var/lib/pulp')
abort 'restore is missing the destructive validation boundary' unless validation_boundary
abort 'restore validates the snapshot after deleting avatars' unless avatar_deletion && validation_boundary < avatar_deletion
abort 'restore validates the snapshot after deleting Pulp data' unless pulp_deletion && validation_boundary < pulp_deletion
secret_validation = restore.index('Secret escrow manifest is incomplete')
abort 'restore validates Secret escrow after destructive changes' unless secret_validation && secret_validation < validation_boundary
abort 'recovery quiescence omits the Katello event daemon' unless common.include?('$component == "katello-event-daemon"')
abort 'recovery ignores terminating writers' if common.include?('.metadata.deletionTimestamp == null')
abort 'recovery does not ignore successful Jobs' unless common.include?('(.status.phase // "") != "Succeeded"')
abort 'recovery does not ignore failed Jobs' unless common.include?('(.status.phase // "") != "Failed"')

puts "Recovery storage includes avatars; Pulp filesystem mounted=#{expect_pulp}."
