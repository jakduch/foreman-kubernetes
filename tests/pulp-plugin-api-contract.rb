# frozen_string_literal: true

require 'json'
require 'yaml'

PLUGIN_CAPABILITIES = {
  'pulp_ansible' => 'ansible',
  'pulp_certguard' => 'certguard',
  'pulp_container' => 'container',
  'pulp_deb' => 'deb',
  'pulp_file' => 'file',
  'pulp_python' => 'python',
  'pulp_rpm' => 'rpm',
  'pulp_smart_proxy' => 'smart_proxy',
}.freeze

def component(resource)
  resource.dig('metadata', 'labels', 'app.kubernetes.io/component')
end

def environment(container)
  Array(container&.fetch('env', nil)).to_h { |entry| [entry.fetch('name'), entry['value']] }
end

def pod_component_peer?(rule, expected_component)
  Array(rule['to'] || rule['from']).any? do |peer|
    labels = peer.dig('podSelector', 'matchLabels') || {}
    expressions = Array(peer.dig('podSelector', 'matchExpressions'))
    labels['app.kubernetes.io/component'] == expected_component || expressions.any? do |expression|
      expression['key'] == 'app.kubernetes.io/component' &&
        expression['operator'] == 'In' &&
        Array(expression['values']).include?(expected_component)
    end
  end
end

manifests = ARGV
abort "usage: #{$PROGRAM_NAME} MANIFEST [...]" if manifests.empty?

manifests.each do |manifest|
  resources = YAML.load_stream(File.read(manifest)).compact

  pulp_api = resources.find { |resource| resource['kind'] == 'Deployment' && component(resource) == 'pulp-api' }
  abort "#{manifest}: Pulp API Deployment is missing" unless pulp_api

  api_container = Array(pulp_api.dig('spec', 'template', 'spec', 'containers')).find do |container|
    container['name'] == 'pulp-api'
  end
  abort "#{manifest}: Pulp API container is missing" unless api_container

  enabled_plugins = JSON.parse(environment(api_container).fetch('PULP_ENABLED_PLUGINS'))
  expected_capabilities = (['core'] + enabled_plugins.map { |plugin| PLUGIN_CAPABILITIES[plugin] }.compact).uniq.sort

  smoke_job = resources.find { |resource| resource['kind'] == 'Job' && component(resource) == 'smoke-test' }
  abort "#{manifest}: smoke-test Job is missing" unless smoke_job

  smoke_container = Array(smoke_job.dig('spec', 'template', 'spec', 'containers')).find do |container|
    container['name'] == 'smoke-test'
  end
  abort "#{manifest}: smoke-test container is missing" unless smoke_container

  smoke_environment = environment(smoke_container)
  actual_capabilities = JSON.parse(smoke_environment.fetch('PULP_EXPECTED_CAPABILITIES')).sort
  unless actual_capabilities == expected_capabilities
    abort "#{manifest}: smoke test expects #{actual_capabilities.inspect}, expected #{expected_capabilities.inspect}"
  end

  control_service = resources.find { |resource| resource['kind'] == 'Service' && component(resource) == 'pulp-control-proxy' }
  abort "#{manifest}: Pulp control proxy Service is missing" unless control_service

  expected_features_url = "https://#{control_service.dig('metadata', 'name')}/pulp/api/v3/smart_proxy/v2/features"
  unless smoke_environment['PULP_FEATURES_URL'] == expected_features_url
    abort "#{manifest}: PULP_FEATURES_URL is #{smoke_environment['PULP_FEATURES_URL'].inspect}, " \
          "expected #{expected_features_url.inspect}"
  end

  smoke_script = Array(smoke_container['args']).join("\n")
  abort "#{manifest}: smoke test does not reject missing Pulp capabilities" unless smoke_script.include?('missing_capabilities')
  unless smoke_script.include?("authentication.include?('client_certificate')")
    abort "#{manifest}: smoke test does not require Pulp client-certificate authentication"
  end

  control_policy = resources.find do |resource|
    resource['kind'] == 'NetworkPolicy' && component(resource) == 'pulp-control-proxy'
  end
  abort "#{manifest}: Pulp control proxy ingress NetworkPolicy is missing" unless control_policy

  unless Array(control_policy.dig('spec', 'ingress')).any? { |rule| pod_component_peer?(rule, 'smoke-test') }
    abort "#{manifest}: Pulp control proxy does not admit the smoke-test pod"
  end

  smoke_egress = resources.find do |resource|
    resource['kind'] == 'NetworkPolicy' && component(resource) == 'smoke-test-egress'
  end
  if smoke_egress
    proxy_deployment = resources.find do |resource|
      resource['kind'] == 'Deployment' && component(resource) == 'pulp-control-proxy'
    end
    proxy_port = Array(proxy_deployment&.dig('spec', 'template', 'spec', 'containers')).flat_map do |container|
      Array(container['ports']).map { |port| port['containerPort'] }
    end.first
    proxy_rule = Array(smoke_egress.dig('spec', 'egress')).find do |rule|
      pod_component_peer?(rule, 'pulp-control-proxy')
    end
    ports = Array(proxy_rule&.fetch('ports', nil)).map { |port| port['port'] }
    unless proxy_rule && ports == [proxy_port]
      abort "#{manifest}: smoke-test egress does not target the Pulp control proxy port #{proxy_port.inspect}"
    end
  end

  puts "Pulp plugin API contract passed for #{manifest}: #{expected_capabilities.join(', ')}."
end
