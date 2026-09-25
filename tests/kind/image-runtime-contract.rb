#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'
require 'pathname'
require 'time'
require 'yaml'

abort 'usage: image-runtime-contract.rb NAMESPACE APPLICATION_PROFILE EXECUTION_PROFILE OUTPUT' unless ARGV.length == 4

root = Pathname.new(File.expand_path('../..', __dir__))
namespace = ARGV.fetch(0)
application_profile_path = Pathname.new(File.expand_path(ARGV.fetch(1)))
execution_profile_path = Pathname.new(File.expand_path(ARGV.fetch(2)))
output_path = Pathname.new(File.expand_path(ARGV.fetch(3)))

application_profile = YAML.safe_load(application_profile_path.read)
execution_profile = YAML.safe_load(execution_profile_path.read)
kind_values = YAML.safe_load((root / 'tests/kind/values.yaml').read)
plugin_matrix = JSON.parse((root / 'compatibility/plugin-matrix.json').read)

def capture!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  return stdout.strip if status.success?

  abort "command failed (#{command.join(' ')}):\n#{stderr}"
end

def image_reference(image)
  "#{image.fetch('repository')}:#{image.fetch('tag')}"
end

def expected_digest(reference)
  match = reference.match(/@(sha256:[0-9a-f]{64})\z/)
  abort "image is not digest-pinned: #{reference}" unless match

  match.fetch(1)
end

def ready_pod!(namespace, selector)
  pods = JSON.parse(capture!(
    'kubectl', '--namespace', namespace, 'get', 'pods',
    '--selector', selector, '--output=json'
  )).fetch('items')
  ready = pods.select do |pod|
    pod.dig('status', 'phase') == 'Running' &&
      pod.fetch('status', {}).fetch('conditions', []).any? do |condition|
        condition['type'] == 'Ready' && condition['status'] == 'True'
      end
  end
  abort "no ready Pod for selector #{selector}" if ready.empty?

  ready.min_by { |pod| pod.dig('metadata', 'name') }
end

def container_status!(pod, container_name)
  pod.fetch('status').fetch('containerStatuses').find do |status|
    status.fetch('name') == container_name
  end || abort("container #{container_name} is missing from #{pod.dig('metadata', 'name')}")
end

def container_spec!(pod, container_name)
  pod.fetch('spec').fetch('containers').find do |container|
    container.fetch('name') == container_name
  end || abort("container #{container_name} is missing from #{pod.dig('metadata', 'name')}")
end

def exec!(namespace, pod_name, container_name, *command)
  capture!(
    'kubectl', '--namespace', namespace, 'exec', pod_name,
    '--container', container_name, '--', *command
  )
end

def validate_component!(namespace:, selector:, container:, reference:, expected_user:, expected_uid:, expected_gid:)
  pod = ready_pod!(namespace, selector)
  pod_name = pod.dig('metadata', 'name')
  specification = container_spec!(pod, container)
  status = container_status!(pod, container)
  digest = expected_digest(reference)

  abort "#{container} Pod does not use #{reference}" unless specification.fetch('image') == reference
  actual_image_id = status.fetch('imageID')
  abort "#{container} image ID #{actual_image_id} does not contain #{digest}" unless actual_image_id.include?("@#{digest}")

  actual_user = exec!(namespace, pod_name, container, 'id', '-un')
  actual_uid = exec!(namespace, pod_name, container, 'id', '-u')
  actual_gid = exec!(namespace, pod_name, container, 'id', '-g')
  abort "#{container} runs as #{actual_user}, expected #{expected_user}" unless actual_user == expected_user
  abort "#{container} runs as UID #{actual_uid}, expected #{expected_uid}" unless expected_uid.nil? || actual_uid == expected_uid.to_s
  abort "#{container} runs as GID #{actual_gid}, expected #{expected_gid}" unless expected_gid.nil? || actual_gid == expected_gid.to_s
  abort "#{container} unexpectedly runs as root" if actual_uid == '0'

  {
    'pod' => pod_name,
    'container' => container,
    'expectedImage' => reference,
    'runtimeImageId' => actual_image_id,
    'user' => {'name' => actual_user, 'uid' => actual_uid.to_i, 'gid' => actual_gid.to_i}
  }
end

set_name = application_profile.dig('platform', 'compatibilitySet')
abort 'application profile has no compatibility-set identity' unless set_name
abort 'execution profile belongs to another compatibility set' unless execution_profile.fetch('compatibilitySet') == set_name

foreman_reference = image_reference(application_profile.dig('foreman', 'image'))
pulp_reference = image_reference(application_profile.dig('pulp', 'image'))
candlepin_reference = image_reference(application_profile.dig('candlepin', 'image'))
proxy_reference = image_reference(execution_profile.fetch('image'))

foreman = validate_component!(
  namespace: namespace,
  selector: 'app.kubernetes.io/component=foreman',
  container: 'foreman',
  reference: foreman_reference,
  expected_user: 'foreman',
  expected_uid: 994,
  expected_gid: 994
)
foreman_plugins = plugin_matrix.fetch('foreman').map { |plugin| plugin.fetch('name') }.sort
foreman_plugins.each do |plugin|
  abort "unsafe Foreman plugin name: #{plugin}" unless plugin.match?(/\A[a-z0-9_-]+\z/)

  exec!(namespace, foreman.fetch('pod'), 'foreman', 'test', '-f', "/usr/share/foreman/bundler.d/#{plugin}.rb")
end
expected_foreman_plugins = kind_values.dig('foreman', 'enabledPlugins').sort
actual_foreman_plugins = exec!(
  namespace, foreman.fetch('pod'), 'foreman', 'printenv', 'FOREMAN_ENABLED_PLUGINS'
).split.sort
abort 'Foreman runtime plugin allow-list differs from the Kind profile' unless actual_foreman_plugins == expected_foreman_plugins
exec!(namespace, foreman.fetch('pod'), 'foreman', 'test', '-x', '/usr/share/foreman/bin/rails')
foreman['package'] = exec!(namespace, foreman.fetch('pod'), 'foreman', 'rpm', '-q', 'foreman')
foreman['packagedPlugins'] = foreman_plugins
foreman['enabledPlugins'] = actual_foreman_plugins

pulp = validate_component!(
  namespace: namespace,
  selector: 'app.kubernetes.io/component=pulp-api',
  container: 'pulp-api',
  reference: pulp_reference,
  expected_user: 'pulp',
  expected_uid: 700,
  expected_gid: 700
)
exec!(namespace, pulp.fetch('pod'), 'pulp-api', 'test', '-x', '/usr/bin/pulpcore-api')
expected_pulp_plugins = kind_values.dig('pulp', 'enabledPlugins').sort
actual_pulp_plugins = JSON.parse(exec!(
  namespace, pulp.fetch('pod'), 'pulp-api', 'printenv', 'PULP_ENABLED_PLUGINS'
)).sort
abort 'Pulp runtime plugin allow-list differs from the Kind profile' unless actual_pulp_plugins == expected_pulp_plugins
pulp_status = JSON.parse(exec!(
  namespace,
  pulp.fetch('pod'),
  'pulp-api',
  'python3',
  '-c',
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:24817/pulp/api/v3/status/').read().decode())"
))
pulp_versions = pulp_status.fetch('versions')
runtime_pulp_plugins = pulp_versions.flat_map do |version|
  version.values_at('component', 'package', 'module').compact.flat_map do |identity|
    normalized = identity.tr('-', '_')
    [normalized, normalized.split('.').first, "pulp_#{normalized}"]
  end
end.uniq
missing_pulp_plugins = expected_pulp_plugins.reject do |plugin|
  runtime_pulp_plugins.include?(plugin) || runtime_pulp_plugins.include?(plugin.delete_prefix('pulp_'))
end
abort "Pulp status omits enabled plugins: #{missing_pulp_plugins.join(', ')}" unless missing_pulp_plugins.empty?
pulp['enabledPlugins'] = actual_pulp_plugins
pulp['versions'] = pulp_versions.sort_by { |version| version.fetch('component', '') }

candlepin = validate_component!(
  namespace: namespace,
  selector: 'app.kubernetes.io/component=candlepin',
  container: 'candlepin',
  reference: candlepin_reference,
  expected_user: 'tomcat',
  expected_uid: nil,
  expected_gid: nil
)
exec!(namespace, candlepin.fetch('pod'), 'candlepin', 'test', '-x', '/usr/libexec/tomcat/server')
candlepin['package'] = exec!(namespace, candlepin.fetch('pod'), 'candlepin', 'rpm', '-q', 'candlepin')
candlepin['java'] = exec!(
  namespace,
  candlepin.fetch('pod'),
  'candlepin',
  'sh',
  '-c',
  'java -version 2>&1 | sed -n 1p'
)

proxy = validate_component!(
  namespace: namespace,
  selector: 'app.kubernetes.io/instance=execution,app.kubernetes.io/component=execution-proxy',
  container: 'foreman-proxy',
  reference: proxy_reference,
  expected_user: 'foreman-proxy',
  expected_uid: 991,
  expected_gid: 991
)
proxy_plugins = plugin_matrix.fetch('smartProxyImagePlugins').map { |plugin| plugin.fetch('name') }.sort
proxy_plugins.each do |plugin|
  abort "unsafe Smart Proxy plugin name: #{plugin}" unless plugin.match?(/\A[a-z0-9_-]+\z/)

  exec!(namespace, proxy.fetch('pod'), 'foreman-proxy', 'test', '-f', "/usr/share/foreman-proxy/bundler.d/#{plugin}.rb")
end
actual_proxy_plugins = exec!(
  namespace, proxy.fetch('pod'), 'foreman-proxy', 'printenv', 'FOREMAN_PROXY_ENABLED_PLUGINS'
).split.sort
expected_proxy_plugins = %w[ansible remote_execution_ssh]
abort 'Smart Proxy runtime plugin allow-list is broader than the execution role' unless actual_proxy_plugins == expected_proxy_plugins
exec!(namespace, proxy.fetch('pod'), 'foreman-proxy', 'test', '-x', '/usr/share/foreman-proxy/bin/smart-proxy')
proxy['package'] = exec!(namespace, proxy.fetch('pod'), 'foreman-proxy', 'rpm', '-q', 'foreman-proxy')
proxy['packagedPlugins'] = proxy_plugins
proxy['enabledPlugins'] = actual_proxy_plugins

report = {
  'schemaVersion' => 1,
  'compatibilitySet' => set_name,
  'checkedAt' => Time.now.utc.iso8601,
  'components' => {
    'foreman' => foreman,
    'pulp' => pulp,
    'candlepin' => candlepin,
    'executionProxy' => proxy
  }
}

output_path.dirname.mkpath
temporary_output = Pathname.new("#{output_path}.tmp.#{Process.pid}")
begin
  temporary_output.write("#{JSON.pretty_generate(report)}\n")
  File.rename(temporary_output, output_path)
ensure
  temporary_output.delete if temporary_output.exist?
end

puts "Verified running images and packaged runtimes for #{set_name}."
