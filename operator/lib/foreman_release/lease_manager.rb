# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require_relative 'command_runner'
require_relative 'reconciler'

module ForemanRelease
  class LeaseLost < StandardError; end

  class LeaseManager
    def initialize(runner: CommandRunner.new, duration_seconds: 120, clock: -> { Time.now.utc })
      raise ArgumentError, 'Lease duration must be at least 30 seconds' if duration_seconds < 30

      @runner = runner
      @duration_seconds = duration_seconds
      @clock = clock
    end

    def acquire(resource, operation)
      namespace = resource.dig('metadata', 'namespace')
      lease_name = name(resource)
      manifest = new_manifest(resource, operation, lease_name)
      create(namespace, manifest)
      Observation.new(state: :succeeded, message: "acquired Lease #{namespace}/#{lease_name}")
    rescue CommandError
      existing = get(namespace, lease_name)
      holder = existing.dig('spec', 'holderIdentity').to_s
      return renew(resource, operation) if holder == operation.fetch('id')
      return Observation.new(state: :busy, message: "Lease #{namespace}/#{lease_name} is held by #{holder}") if active?(existing)

      replacement = claimed_manifest(existing, resource, operation)
      begin
        replace(namespace, replacement)
        Observation.new(state: :succeeded, message: "claimed expired Lease #{namespace}/#{lease_name}")
      rescue CommandError
        current = get(namespace, lease_name)
        current_holder = current.dig('spec', 'holderIdentity').to_s
        if current_holder == operation.fetch('id')
          Observation.new(state: :succeeded, message: "adopted Lease #{namespace}/#{lease_name}")
        elsif active?(current)
          Observation.new(state: :busy, message: "Lease #{namespace}/#{lease_name} changed owner")
        else
          raise
        end
      end
    end

    def renew(resource, operation)
      namespace = resource.dig('metadata', 'namespace')
      lease_name = name(resource)
      existing = get(namespace, lease_name)
      holder = existing.dig('spec', 'holderIdentity').to_s
      unless holder == operation.fetch('id')
        raise LeaseLost, "Lease #{namespace}/#{lease_name} is owned by #{holder.empty? ? 'nobody' : holder}"
      end

      replacement = existing.slice('apiVersion', 'kind', 'metadata', 'spec')
      replacement['metadata'] = identity_metadata(existing)
      replacement['spec'] = existing.fetch('spec').merge(
        'leaseDurationSeconds' => @duration_seconds,
        'renewTime' => timestamp
      )
      replace(namespace, replacement)
      Observation.new(state: :succeeded, message: "renewed Lease #{namespace}/#{lease_name}")
    end

    def release(resource, operation)
      namespace = resource.dig('metadata', 'namespace')
      lease_name = name(resource)
      existing = get(namespace, lease_name)
      return false unless existing.dig('spec', 'holderIdentity').to_s == operation['id'].to_s

      replacement = existing.slice('apiVersion', 'kind', 'metadata', 'spec')
      replacement['metadata'] = identity_metadata(existing)
      replacement['metadata']['annotations'] = (replacement['metadata']['annotations'] || {}).merge(
        'foreman-kubernetes.io/released-at' => timestamp
      )
      replacement['spec'] = existing.fetch('spec').merge(
        'holderIdentity' => '',
        'leaseDurationSeconds' => 1,
        'renewTime' => timestamp
      )
      replace(namespace, replacement)
      true
    rescue CommandError
      false
    end

    def name(resource)
      raw = "#{resource.dig('metadata', 'name')}-foreman-release"
      return raw if raw.length <= 63

      "#{raw[0, 54].sub(/-+\z/, '')}-#{Digest::SHA256.hexdigest(raw)[0, 8]}"
    end

    private

    def new_manifest(resource, operation, lease_name)
      now = timestamp
      {
        'apiVersion' => 'coordination.k8s.io/v1',
        'kind' => 'Lease',
        'metadata' => {
          'namespace' => resource.dig('metadata', 'namespace'),
          'name' => lease_name,
          'labels' => {
            'platform.theforeman.org/release-owner' => resource.dig('metadata', 'uid')
          },
          'annotations' => {
            'foreman-kubernetes.io/compatibility-set' => resource.dig('spec', 'compatibilitySet')
          }
        },
        'spec' => {
          'holderIdentity' => operation.fetch('id'),
          'leaseDurationSeconds' => @duration_seconds,
          'acquireTime' => now,
          'renewTime' => now
        }
      }
    end

    def claimed_manifest(existing, resource, operation)
      manifest = new_manifest(resource, operation, existing.dig('metadata', 'name'))
      manifest['metadata'] = manifest.fetch('metadata').merge(
        'resourceVersion' => existing.dig('metadata', 'resourceVersion')
      )
      manifest
    end

    def active?(lease)
      holder = lease.dig('spec', 'holderIdentity').to_s
      return false if holder.empty?

      renewed_at = lease.dig('spec', 'renewTime') || lease.dig('spec', 'acquireTime')
      duration = Integer(lease.dig('spec', 'leaseDurationSeconds'))
      raise LeaseLost, 'Lease has no valid expiration contract' if renewed_at.nil? || duration <= 0

      @clock.call.utc < Time.iso8601(renewed_at).utc + duration
    rescue ArgumentError, TypeError
      raise LeaseLost, 'Lease has no valid expiration contract'
    end

    def identity_metadata(lease)
      metadata = lease.fetch('metadata')
      {
        'namespace' => metadata.fetch('namespace'),
        'name' => metadata.fetch('name'),
        'resourceVersion' => metadata.fetch('resourceVersion'),
        'labels' => metadata['labels'],
        'annotations' => metadata['annotations']
      }.reject { |_key, value| value.nil? }
    end

    def timestamp
      @clock.call.utc.iso8601
    end

    def create(namespace, manifest)
      @runner.run(
        'kubectl', '--namespace', namespace, 'create', '--filename=-', '--output=json',
        stdin_data: JSON.generate(manifest)
      )
    end

    def get(namespace, lease_name)
      response = @runner.run(
        'kubectl', '--namespace', namespace, 'get', 'lease', lease_name, '--output=json'
      )
      JSON.parse(response)
    end

    def replace(namespace, manifest)
      @runner.run(
        'kubectl', '--namespace', namespace, 'replace', '--filename=-', '--output=json',
        stdin_data: JSON.generate(manifest)
      )
    end
  end
end
