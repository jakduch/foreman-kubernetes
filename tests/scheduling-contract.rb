# frozen_string_literal: true

require 'yaml'

EXPECTED_NODE_SELECTOR = {'platform.theforeman.org/pool' => 'foreman'}.freeze
EXPECTED_TOLERATION = {
  'key' => 'platform.theforeman.org/dedicated',
  'operator' => 'Equal',
  'value' => 'foreman',
  'effect' => 'NoSchedule',
}.freeze

def pod_spec(document)
  case document['kind']
  when 'Pod'
    document['spec']
  when 'Deployment', 'StatefulSet', 'DaemonSet', 'Job'
    document.dig('spec', 'template', 'spec')
  when 'CronJob'
    document.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  end
end

ARGV.each do |path|
  documents = YAML.load_stream(File.read(path)).compact
  workloads = documents.each_with_object([]) do |document, found|
    spec = pod_spec(document)
    found << [document.fetch('kind'), document.dig('metadata', 'name'), spec] if spec
  end
  abort "#{path}: no pod-producing workload was rendered" if workloads.empty?

  workloads.each do |kind, name, spec|
    identity = "#{kind}/#{name}"
    unless spec['priorityClassName'] == 'foreman-platform-critical'
      abort "#{path}: #{identity} is missing the configured PriorityClass"
    end
    unless spec['nodeSelector'] == EXPECTED_NODE_SELECTOR
      abort "#{path}: #{identity} is missing the configured node selector"
    end
    unless Array(spec['tolerations']).include?(EXPECTED_TOLERATION)
      abort "#{path}: #{identity} is missing the configured toleration"
    end
  end
end
