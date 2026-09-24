#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'
require 'time'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/reconciler').to_s

class FakeAdapter
  attr_reader :calls, :migration_operations

  def initialize
    @calls = []
    @results = Hash.new { |hash, key| hash[key] = [:succeeded] }
    @migration_operations = []
  end

  def results(method, *states)
    @results[method] = states
  end

  %i[validate acquire_lease renew_lease ensure_migrations ensure_application ensure_application_smoke ensure_proxy ensure_final_smoke].each do |method|
    define_method(method) do |_resource, operation|
      @calls << method
      @migration_operations << operation.fetch('id') if method == :ensure_migrations
      states = @results[method]
      state = states.length > 1 ? states.shift : states.first
      ForemanRelease::Observation.new(
        state: state,
        message: "#{method} is #{state}",
        details: method == :ensure_migrations ? {migrationJobs: %w[job-a job-b job-c]} : {}
      )
    end
  end

  def release_lease(_resource, operation)
    @calls << [:release_lease, operation['id']]
  end

  def prune_operation_history(_resource, operation)
    @calls << [:prune_operation_history, operation['id']]
    states = @results[:prune_operation_history]
    state = states.length > 1 ? states.shift : states.first
    ForemanRelease::Observation.new(state: state, message: "history cleanup is #{state}")
  end
end

def resource(generation: 1, compatibility_set: 'candidate-1', retry_token: '', reconcile_token: '', paused: false,
             status: nil)
  value = {
    'metadata' => {
      'name' => 'foreman',
      'namespace' => 'foreman',
      'uid' => '12345678-1234-1234-1234-123456789abc',
      'generation' => generation,
      'resourceVersion' => generation.to_s
    },
    'spec' => {
      'compatibilitySet' => compatibility_set,
      'retryToken' => retry_token,
      'reconcileToken' => reconcile_token,
      'paused' => paused
    }
  }
  value['status'] = status if status
  value
end

machine = ForemanRelease::StateMachine.load(root.join('operator/release-state-machine.json'))
adapter = FakeAdapter.new
adapter.results(:ensure_migrations, :pending, :succeeded)
writes = []
reconciler = ForemanRelease::Reconciler.new(
  state_machine: machine,
  adapter: adapter,
  status_writer: lambda do |release, status|
    release['status'] = status
    writes << Marshal.load(Marshal.dump(status))
  end,
  clock: -> { '2026-09-24T12:00:00Z' }
)
release = resource

expected_phases = %w[Preflight AcquiringLock Migrating Migrating RollingApplication VerifyingApplication RollingProxy Verifying Ready]
expected_phases.each do |phase|
  reconciler.reconcile(release)
  actual = release.dig('status', 'phase')
  raise "expected #{phase}, got #{actual}" unless actual == phase
end

operation_id = '12345678-1234-1234-1234-123456789abc-g1'
raise 'reconciliation did not use a deterministic operation ID' unless release.dig('status', 'operation', 'id') == operation_id
raise 'migration Jobs were not adopted with one operation ID' unless adapter.migration_operations == [operation_id, operation_id]
raise 'successful migrations were not recorded' unless release.dig('status', 'operation', 'migrationJobs') == %w[job-a job-b job-c]
raise 'ready reconciliation did not release the Lease' unless adapter.calls.include?([:release_lease, operation_id])
raise 'ready reconciliation did not checkpoint cleanup' unless reconciler.reconcile(release) == :idle
raise 'ready reconciliation did not prune old operation history' unless adapter.calls.include?([:prune_operation_history, operation_id])
raise 'cleanup did not record its operation' unless release.dig('status', 'historyPrunedThroughOperation') == operation_id
raise 'cleanup did not record its retention limit' unless release.dig('status', 'historyPrunedLimit') == 3
raise 'ready reconciliation did not record the set' unless release.dig('status', 'currentSet') == 'candidate-1'

release['spec']['reconcileToken'] = 'rotate-certificates'
release['metadata']['generation'] = 2
reconciler.reconcile(release)
raise 'reconcile token did not restart validation' unless release.dig('status', 'phase') == 'Preflight'
raise 'reconcile token did not create a new operation' unless release.dig('status', 'operation', 'id').end_with?('-g2')
unless release.dig('status', 'observedReconcileToken') == 'rotate-certificates'
  raise 'reconcile token was not recorded durably'
end

# Finish the second operation before testing terminal pause behavior.
7.times { reconciler.reconcile(release) }
raise 'reconciled release did not return to Ready' unless release.dig('status', 'phase') == 'Ready'

release['spec']['paused'] = true
release['metadata']['generation'] = 3
raise 'ready release did not publish its paused state' unless reconciler.reconcile(release) == :paused
release['spec']['paused'] = false
release['metadata']['generation'] = 4
raise 'ready release did not accept resume' unless reconciler.reconcile(release) == :idle
raise 'ready release retained Paused=True after resume' unless release['status']['conditions'].find { |c| c['type'] == 'Paused' }['status'] == 'False'

release['spec']['timeouts'] = {'preflightSeconds' => 600}
release['metadata']['generation'] = 5
raise 'idle spec update did not remain idle' unless reconciler.reconcile(release) == :idle
raise 'idle spec generation was not acknowledged' unless release.dig('status', 'observedGeneration') == 5

cleanup_adapter = FakeAdapter.new
cleanup_adapter.results(:prune_operation_history, :failed)
cleanup_release = resource(status: {
  'phase' => 'Ready',
  'currentSet' => 'candidate-1',
  'observedGeneration' => 1,
  'operation' => {'id' => operation_id, 'startedAt' => '2026-09-24T12:00:00Z'}
})
cleanup_reconciler = ForemanRelease::Reconciler.new(
  state_machine: machine,
  adapter: cleanup_adapter,
  status_writer: ->(_item, _status) { raise 'cleanup failure changed Ready status' }
)
unless cleanup_reconciler.reconcile(cleanup_release) == :cleanup_pending
  raise 'failed best-effort history cleanup was not exposed for retry'
end
raise 'cleanup failure degraded a healthy release' unless cleanup_release.dig('status', 'phase') == 'Ready'

conflicting_writer = ForemanRelease::Reconciler.new(
  state_machine: machine,
  adapter: FakeAdapter.new,
  status_writer: ->(_item, _status) { raise 'resourceVersion conflict' },
  clock: -> { '2026-09-24T12:00:30Z' }
)
begin
  conflicting_writer.reconcile(resource)
  raise 'status conflict was swallowed as a release failure'
rescue RuntimeError => error
  raise unless error.message == 'resourceVersion conflict'
end

# A new reconciler instance resumes the persisted operation instead of creating another one.
restarted_adapter = FakeAdapter.new
restarted_adapter.results(:ensure_migrations, :succeeded)
restarted_release = resource(status: {
  'phase' => 'Migrating',
  'targetSet' => 'candidate-1',
  'operation' => {'id' => operation_id, 'startedAt' => '2026-09-24T12:00:00Z', 'migrationJobs' => []}
})
restarted = ForemanRelease::Reconciler.new(
  state_machine: machine,
  adapter: restarted_adapter,
  status_writer: ->(item, status) { item['status'] = status },
  clock: -> { '2026-09-24T12:01:00Z' }
)
restarted.reconcile(restarted_release)
raise 'restart did not adopt the persisted operation' unless restarted_adapter.migration_operations == [operation_id]
raise 'restart did not advance after adopted migrations' unless restarted_release.dig('status', 'phase') == 'RollingApplication'

# A replacement controller keeps the durable operation but cannot mutate it
# while the previous Pod still owns the operation Lease.
fenced_adapter = FakeAdapter.new
fenced_adapter.results(:renew_lease, :busy)
fenced_release = resource(status: {
  'phase' => 'Migrating',
  'targetSet' => 'candidate-1',
  'operation' => {'id' => operation_id, 'startedAt' => '2026-09-24T12:00:00Z', 'migrationJobs' => []}
})
fenced = ForemanRelease::Reconciler.new(
  state_machine: machine,
  adapter: fenced_adapter,
  status_writer: ->(item, status) { item['status'] = status },
  clock: -> { '2026-09-24T12:01:00Z' }
)
raise 'replacement controller did not wait for the live operation holder' unless fenced.reconcile(fenced_release) == :requeue
raise 'fenced controller touched migration state' unless fenced_adapter.calls == [:renew_lease]
raise 'Lease contention changed the active phase' unless fenced_release.dig('status', 'phase') == 'Migrating'

# Pause observes an active migration but prevents the application rollout.
pause_adapter = FakeAdapter.new
pause_adapter.results(:ensure_migrations, :succeeded)
paused_release = resource(paused: true, status: {
  'phase' => 'Migrating',
  'targetSet' => 'candidate-1',
  'operation' => {'id' => operation_id, 'startedAt' => '2026-09-24T12:00:00Z', 'migrationJobs' => []}
})
paused_reconciler = ForemanRelease::Reconciler.new(
  state_machine: machine,
  adapter: pause_adapter,
  status_writer: ->(item, status) { item['status'] = status },
  clock: -> { '2026-09-24T12:02:00Z' }
)
raise 'active migration did not pause at its safe boundary' unless paused_reconciler.reconcile(paused_release) == :paused
raise 'pause advanced beyond migrations' unless paused_release.dig('status', 'phase') == 'Migrating'
raise 'pause did not renew and observe migrations' unless pause_adapter.calls == %i[renew_lease ensure_migrations]

paused_release['spec']['paused'] = false
paused_release['metadata']['generation'] = 2
paused_reconciler.reconcile(paused_release)
raise 'unpaused release did not continue' unless paused_release.dig('status', 'phase') == 'RollingApplication'

# Deletion waits for an active phase, records a safe pause, and only then
# releases the operation Lease so the finalizer can be removed next cycle.
deletion_adapter = FakeAdapter.new
deletion_adapter.results(:ensure_migrations, :pending, :succeeded)
deleting_release = resource(status: {
  'phase' => 'Migrating',
  'targetSet' => 'candidate-1',
  'operation' => {'id' => operation_id, 'startedAt' => '2026-09-24T12:00:00Z', 'migrationJobs' => []}
})
deletion_reconciler = ForemanRelease::Reconciler.new(
  state_machine: machine,
  adapter: deletion_adapter,
  status_writer: ->(_item, status) { deleting_release['status'] = status },
  clock: -> { '2026-09-24T12:02:30Z' }
)
raise 'deletion did not wait for pending migrations' unless deletion_reconciler.quiesce(deleting_release) == :requeue
raise 'deletion removed protection before the active phase completed' if deletion_adapter.calls.include?([:release_lease, operation_id])
premature_pause = Array(deleting_release.dig('status', 'conditions')).find do |condition|
  condition['type'] == 'Paused' && condition['status'] == 'True'
end
raise 'pending migration was marked as a safe pause boundary' if premature_pause
raise 'completed phase did not persist a safe deletion pause' unless deletion_reconciler.quiesce(deleting_release) == :requeue
paused_condition = deleting_release['status']['conditions'].find { |condition| condition['type'] == 'Paused' }
raise 'safe deletion boundary was not persisted' unless paused_condition&.fetch('status') == 'True'
raise 'persisted safe boundary was not finalized' unless deletion_reconciler.quiesce(deleting_release) == :safe
raise 'finalization did not release the operation Lease' unless deletion_adapter.calls.last == [:release_lease, operation_id]

failover_deletion_adapter = FakeAdapter.new
failover_deletion_adapter.results(:renew_lease, :busy, :succeeded)
failover_release = resource(status: Marshal.load(Marshal.dump(deleting_release['status'])))
failover_deletion = ForemanRelease::Reconciler.new(
  state_machine: machine,
  adapter: failover_deletion_adapter,
  status_writer: ->(_item, _status) { raise 'fenced deletion wrote status' }
)
raise 'replacement leader bypassed the live operation holder' unless failover_deletion.quiesce(failover_release) == :requeue
raise 'replacement leader released a foreign operation Lease' if failover_deletion_adapter.calls.any? do |call|
  call.is_a?(Array) && call.first == :release_lease
end
raise 'replacement leader did not finalize after Lease takeover' unless failover_deletion.quiesce(failover_release) == :safe

terminal_deletion_adapter = FakeAdapter.new
terminal_deletion = ForemanRelease::Reconciler.new(
  state_machine: machine,
  adapter: terminal_deletion_adapter,
  status_writer: ->(_item, _status) { raise 'terminal deletion wrote status' }
)
ready_for_deletion = resource(status: {'phase' => 'Ready', 'currentSet' => 'candidate-1'})
raise 'ready release was not immediately safe to delete' unless terminal_deletion.quiesce(ready_for_deletion) == :safe
orphaned_terminal = resource(status: {
  'phase' => 'Ready',
  'currentSet' => 'candidate-1',
  'operation' => {'id' => operation_id, 'startedAt' => '2026-09-24T12:00:00Z'}
})
raise 'terminal release did not clean up its operation Lease' unless terminal_deletion.quiesce(orphaned_terminal) == :safe
raise 'terminal cleanup did not release its operation Lease' unless terminal_deletion_adapter.calls.last == [:release_lease, operation_id]

# Failures block once and require a changed retry token to create a new operation.
failure_adapter = FakeAdapter.new
failure_adapter.results(:validate, :failed)
failed_release = resource(retry_token: 'attempt-1')
failure_reconciler = ForemanRelease::Reconciler.new(
  state_machine: machine,
  adapter: failure_adapter,
  status_writer: ->(item, status) { item['status'] = status },
  clock: -> { '2026-09-24T12:03:00Z' }
)
failure_reconciler.reconcile(failed_release)
raise 'initial failure setup did not enter preflight' unless failed_release.dig('status', 'phase') == 'Preflight'
failure_reconciler.reconcile(failed_release)
raise 'validation failure did not block' unless failed_release.dig('status', 'phase') == 'Blocked'
calls_before_retry = failure_adapter.calls.length
raise 'unchanged blocked release did not remain idle' unless failure_reconciler.reconcile(failed_release) == :idle
raise 'blocked release retried work without a token change' unless failure_adapter.calls.length == calls_before_retry

failed_release['spec']['retryToken'] = 'attempt-2'
failed_release['metadata']['generation'] = 2
failure_reconciler.reconcile(failed_release)
raise 'changed retry token did not restart preflight' unless failed_release.dig('status', 'phase') == 'Preflight'
raise 'retry reused the failed operation' unless failed_release.dig('status', 'operation', 'id').end_with?('-g2')

# A rollout that never reaches a terminal Deployment condition is bounded by
# the CR phase timeout and releases its operation Lease.
timeout_adapter = FakeAdapter.new
timed_out_release = resource(status: {
  'phase' => 'RollingProxy',
  'phaseStartedAt' => '2026-09-24T12:00:00Z',
  'targetSet' => 'candidate-1',
  'operation' => {'id' => operation_id, 'startedAt' => '2026-09-24T11:45:00Z', 'migrationJobs' => []}
})
timed_out_release['spec']['timeouts'] = {'proxyRolloutSeconds' => 120}
timeout_reconciler = ForemanRelease::Reconciler.new(
  state_machine: machine,
  adapter: timeout_adapter,
  status_writer: ->(item, status) { item['status'] = status },
  clock: -> { '2026-09-24T12:03:00Z' }
)
raise 'expired proxy rollout did not block' unless timeout_reconciler.reconcile(timed_out_release) == :blocked
raise 'expired proxy rollout still called its adapter' if timeout_adapter.calls.include?(:ensure_proxy)
raise 'expired rollout did not renew then release its Lease' unless timeout_adapter.calls == [
  :renew_lease, [:release_lease, operation_id]
]
raise 'timeout phase was not retained' unless timed_out_release.dig('status', 'operation', 'timedOutPhase') == 'RollingProxy'
raise 'timeout budget was not retained' unless timed_out_release.dig('status', 'operation', 'timeoutSeconds') == 120
timeout_condition = timed_out_release['status']['conditions'].find { |condition| condition['type'] == 'Degraded' }
raise 'timeout did not explain the degraded state' unless timeout_condition['message'].include?('120-second timeout')

puts 'ForemanRelease reconciliation is restart-safe, pausable, and explicitly retryable.'
