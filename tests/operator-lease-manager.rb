#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/lease_manager').to_s

class LeaseRunner
  attr_reader :calls

  def initialize
    @lease = nil
    @calls = []
    @fail_next_replace = false
  end

  attr_writer :lease

  def fail_next_replace!
    @fail_next_replace = true
  end

  def run(*command, stdin_data: '')
    @calls << [command, stdin_data]
    action = command.fetch(3)
    case action
    when 'create'
      raise ForemanRelease::CommandError.new(command, 'AlreadyExists', 1) if @lease

      @lease = JSON.parse(stdin_data)
      @lease['metadata']['resourceVersion'] = '1'
      JSON.generate(@lease)
    when 'get'
      raise ForemanRelease::CommandError.new(command, 'NotFound', 1) unless @lease

      JSON.generate(@lease)
    when 'replace'
      if @fail_next_replace
        @fail_next_replace = false
        raise ForemanRelease::CommandError.new(command, 'Conflict', 1)
      end
      replacement = JSON.parse(stdin_data)
      expected = @lease.dig('metadata', 'resourceVersion')
      unless replacement.dig('metadata', 'resourceVersion') == expected
        raise ForemanRelease::CommandError.new(command, 'Conflict', 1)
      end

      replacement['metadata']['resourceVersion'] = (Integer(expected) + 1).to_s
      @lease = replacement
      JSON.generate(@lease)
    else
      raise "unexpected kubectl action: #{action}"
    end
  end

  def lease
    Marshal.load(Marshal.dump(@lease))
  end
end

def release
  {
    'metadata' => {
      'name' => 'foreman',
      'namespace' => 'platform',
      'uid' => '12345678-1234-1234-1234-123456789abc'
    },
    'spec' => {'compatibilitySet' => 'candidate-1'}
  }
end

now = Time.iso8601('2026-09-24T12:00:00Z')
runner = LeaseRunner.new
manager = ForemanRelease::LeaseManager.new(runner: runner, clock: -> { now })
operation = {'id' => '12345678-1234-1234-1234-123456789abc-g1'}

raise 'fresh Lease was not acquired' unless manager.acquire(release, operation).state == :succeeded
raise 'Lease did not record the operation holder' unless runner.lease.dig('spec', 'holderIdentity') == operation['id']
raise 'Lease did not record the release owner' unless runner.lease.dig('metadata', 'labels', 'platform.theforeman.org/release-owner') == release.dig('metadata', 'uid')

now += 20
raise 'owned Lease was not adopted and renewed' unless manager.acquire(release, operation).state == :succeeded
raise 'renewTime did not advance' unless runner.lease.dig('spec', 'renewTime') == now.utc.iso8601

other = runner.lease
other['spec']['holderIdentity'] = 'another-operation'
other['spec']['renewTime'] = now.utc.iso8601
runner.lease = other
raise 'active foreign Lease was not reported busy' unless manager.acquire(release, operation).state == :busy

expired = runner.lease
expired['spec']['renewTime'] = (now - 300).utc.iso8601
runner.lease = expired
raise 'expired Lease was not claimed' unless manager.acquire(release, operation).state == :succeeded
raise 'expired Lease retained its old holder' unless runner.lease.dig('spec', 'holderIdentity') == operation['id']

raise 'owned Lease was not released' unless manager.release(release, operation)
raise 'release deleted instead of retaining the Lease object' unless runner.lease
raise 'released Lease still has a holder' unless runner.lease.dig('spec', 'holderIdentity') == ''
raise 'released Lease was not immediately claimable' unless manager.acquire(release, {'id' => 'next-operation'}).state == :succeeded

foreign = runner.lease
foreign['spec']['holderIdentity'] = 'foreign-operation'
runner.lease = foreign
raise 'release touched a foreign Lease' if manager.release(release, operation)
raise 'foreign Lease holder changed' unless runner.lease.dig('spec', 'holderIdentity') == 'foreign-operation'

invalid = runner.lease
invalid['spec'].delete('renewTime')
invalid['spec'].delete('acquireTime')
runner.lease = invalid
begin
  manager.acquire(release, operation)
  raise 'invalid Lease expiry was accepted'
rescue ForemanRelease::LeaseLost => error
  raise unless error.message.include?('expiration contract')
end

raise 'controller does not share the guarded workflow Lease' unless manager.name(release) == 'foreman-kubernetes-release'
begin
  ForemanRelease::LeaseManager.new(lease_name: 'Invalid_Name')
  raise 'invalid shared Lease name was accepted'
rescue ArgumentError => error
  raise unless error.message.include?('valid DNS label')
end

puts 'ForemanRelease Lease acquisition, renewal, expiry, and safe release passed.'
