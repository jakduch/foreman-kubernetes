#!/usr/bin/env ruby
# frozen_string_literal: true

require 'yaml'

documents = YAML.load_stream(File.read(ARGV.fetch(0))).compact
foreman_ingress = documents.find do |resource|
  resource['kind'] == 'Ingress' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'foreman-edge'
end
abort 'Foreman Ingress is missing' unless foreman_ingress

annotations = foreman_ingress.dig('metadata', 'annotations') || {}
abort 'Foreman Ingress does not require optional verified client certificates' unless \
  annotations['nginx.ingress.kubernetes.io/auth-tls-verify-client'] == 'optional'
abort 'Foreman Ingress does not pass client certificates upstream' unless \
  annotations['nginx.ingress.kubernetes.io/auth-tls-pass-certificate-to-upstream'] == 'true'

header_reference = annotations['nginx.ingress.kubernetes.io/proxy-set-headers'].to_s
header_name = header_reference.split('/', 2).last
headers = documents.find do |resource|
  resource['kind'] == 'ConfigMap' && resource.dig('metadata', 'name') == header_name
end
abort 'Foreman trusted client-header ConfigMap is missing' unless headers

expected_headers = {
  'SSL-CLIENT-CERT' => '$ssl_client_escaped_cert',
  'SSL-CLIENT-S-DN' => '$ssl_client_s_dn',
  'SSL-CLIENT-VERIFY' => '$ssl_client_verify'
}
abort "unexpected Foreman client headers: #{headers['data'].inspect}" unless headers['data'] == expected_headers

config = documents.find do |resource|
  resource['kind'] == 'ConfigMap' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'foreman-config'
end
abort 'Foreman runtime ConfigMap is missing' unless config

settings = config.dig('data', 'settings.yaml').to_s
%w[
  :ssl_client_cert_env:\ HTTP_SSL_CLIENT_CERT
  :ssl_client_dn_env:\ HTTP_SSL_CLIENT_S_DN
  :ssl_client_verify_env:\ HTTP_SSL_CLIENT_VERIFY
].each do |setting|
  abort "Foreman client-certificate setting is missing: #{setting}" unless settings.include?(setting)
end

initializer = config.dig('data', 'foreman-kubernetes-client-certificate.rb').to_s
RubyVM::InstructionSequence.compile(initializer)
abort 'Foreman does not decode ingress-nginx escaped certificates' unless initializer.include?('CGI.unescape(certificate)')
abort 'Foreman certificate middleware decodes arbitrary header content' unless \
  initializer.include?("start_with?(ESCAPED_PEM_PREFIX)")

middleware = Object.new
middleware.define_singleton_method(:insert_before) { |_position, _type| }
configuration = Struct.new(:middleware).new(middleware)
application = Struct.new(:config).new(configuration)
rails = Module.new
rails.define_singleton_method(:application) { application }
Object.const_set(:Rails, rails)
eval(initializer, TOPLEVEL_BINDING) # rubocop:disable Security/Eval

captured_environment = nil
application_endpoint = lambda do |environment|
  captured_environment = environment
  [200, {}, []]
end
adapter = ForemanKubernetesClientCertificate.new(application_endpoint)
adapter.call(
  'HTTP_SSL_CLIENT_CERT' =>
    '-----BEGIN%20CERTIFICATE-----%0AQUJD%0A-----END%20CERTIFICATE-----%0A'
)
expected_certificate = "-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----\n"
abort 'escaped ingress client certificate was not decoded' unless \
  captured_environment['HTTP_SSL_CLIENT_CERT'] == expected_certificate

adapter.call('HTTP_SSL_CLIENT_CERT' => 'untrusted%20header')
abort 'arbitrary client certificate header was decoded' unless \
  captured_environment['HTTP_SSL_CLIENT_CERT'] == 'untrusted%20header'

foreman = documents.find do |resource|
  resource['kind'] == 'Deployment' &&
    resource.dig('metadata', 'labels', 'app.kubernetes.io/component') == 'foreman'
end
mounts = Array(foreman&.dig('spec', 'template', 'spec', 'containers', 0, 'volumeMounts'))
abort 'Foreman does not mount the client-certificate middleware' unless mounts.any? do |mount|
  mount['mountPath'] == '/usr/share/foreman/config/initializers/foreman_kubernetes_client_certificate.rb'
end

puts 'Foreman ingress client-certificate contract passed.'
