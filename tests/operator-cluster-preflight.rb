#!/usr/bin/env ruby
# frozen_string_literal: true

require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/cluster_preflight').to_s

class PreflightKubernetesClient
  attr_accessor :objects

  def initialize
    @objects = {}
  end

  def resources(namespace, type, labels: {})
    raise 'cluster-scoped resource list unexpectedly used a namespace' unless namespace.nil?
    raise 'preflight list unexpectedly used labels' unless labels.empty?
    raise "unexpected list #{type}" unless type == 'storageclasses'

    [
      {
        'metadata' => {
          'name' => 'standard',
          'annotations' => {'storageclass.kubernetes.io/is-default-class' => 'true'}
        }
      }
    ]
  end

  def resource(namespace, type, name)
    @objects.fetch([namespace, type, name])
  rescue KeyError
    command = ['kubectl', 'get', type, name]
    raise ForemanRelease::CommandError.new(command, 'NotFound', 1)
  end
end

class PreflightRunner
  attr_accessor :fail
  attr_reader :calls

  def initialize
    @calls = []
    @fail = false
  end

  def run(*command, stdin_data: '')
    @calls << [command, stdin_data]
    raise ForemanRelease::CommandError.new(command, 'denied by admission policy', 1) if fail

    ''
  end
end

class PreflightCertificateValidator
  attr_reader :calls

  def initialize
    @calls = []
  end

  def validate_secret!(*arguments)
    @calls << arguments
    nil
  end
end

documents = [
  {
    'apiVersion' => 'v1',
    'kind' => 'PersistentVolumeClaim',
    'metadata' => {'name' => 'generated'},
    'spec' => {'accessModes' => ['ReadWriteOnce']}
  },
  {
    'apiVersion' => 'v1',
    'kind' => 'PersistentVolumeClaim',
    'metadata' => {'name' => 'generated-fast'},
    'spec' => {'storageClassName' => 'fast-rwx', 'accessModes' => ['ReadWriteMany']}
  },
  {
    'apiVersion' => 'networking.k8s.io/v1',
    'kind' => 'Ingress',
    'metadata' => {
      'annotations' => {
        'foreman-kubernetes.io/required-ingress-controller' => 'k8s.io/ingress-nginx',
        'nginx.ingress.kubernetes.io/auth-tls-secret' => 'platform/ingress-ca'
      }
    },
    'spec' => {
      'ingressClassName' => 'nginx',
      'rules' => [{'host' => 'foreman.example.test'}],
      'tls' => [{'secretName' => 'ingress-tls', 'hosts' => ['foreman.example.test']}]
    }
  },
  {
    'apiVersion' => 'networking.k8s.io/v1',
    'kind' => 'Ingress',
    'metadata' => {'name' => 'content'},
    'spec' => {
      'rules' => [{'host' => 'content.example.test'}],
      'tls' => [{'secretName' => 'ingress-tls'}]
    }
  },
  {
    'apiVersion' => 'autoscaling/v2',
    'kind' => 'HorizontalPodAutoscaler',
    'metadata' => {'name' => 'web'},
    'spec' => {'metrics' => [{'type' => 'Resource'}]}
  },
  {
    'apiVersion' => 'monitoring.coreos.com/v1',
    'kind' => 'PrometheusRule',
    'metadata' => {'name' => 'foreman'}
  },
  {
    'apiVersion' => 'apps/v1',
    'kind' => 'Deployment',
    'metadata' => {'name' => 'web'},
    'spec' => {
      'template' => {
        'spec' => {
          'priorityClassName' => 'foreman-platform-critical',
          'serviceAccountName' => 'external-runtime',
          'containers' => [
            {
              'name' => 'web',
              'env' => [
                {
                  'name' => 'PASSWORD',
                  'valueFrom' => {'secretKeyRef' => {'name' => 'database', 'key' => 'password'}}
                }
              ]
            }
          ],
          'volumes' => [
            {'name' => 'content', 'persistentVolumeClaim' => {'claimName' => 'imported-content'}}
          ]
        }
      }
    }
  }
]

client = PreflightKubernetesClient.new
client.objects = {
  [nil, 'storageclass', 'fast-rwx'] => {'metadata' => {'name' => 'fast-rwx'}},
  [nil, 'ingressclass', 'nginx'] => {'spec' => {'controller' => 'k8s.io/ingress-nginx'}},
  [nil, 'apiservice', 'v1beta1.metrics.k8s.io'] => {
    'status' => {'conditions' => [{'type' => 'Available', 'status' => 'True'}]}
  },
  [nil, 'customresourcedefinition', 'prometheusrules.monitoring.coreos.com'] => {
    'metadata' => {'name' => 'prometheusrules.monitoring.coreos.com'}
  },
  [nil, 'priorityclass', 'foreman-platform-critical'] => {
    'metadata' => {'name' => 'foreman-platform-critical'}
  },
  ['platform', 'persistentvolumeclaim', 'imported-content'] => {'metadata' => {'name' => 'imported-content'}},
  ['platform', 'serviceaccount', 'external-runtime'] => {'metadata' => {'name' => 'external-runtime'}},
  ['platform', 'secret', 'database'] => {
    'metadata' => {'resourceVersion' => '11'}, 'data' => {'password' => 'encoded'}
  },
  ['platform', 'secret', 'ingress-ca'] => {
    'metadata' => {'resourceVersion' => '12'}, 'data' => {'ca.crt' => 'encoded'}
  },
  ['platform', 'secret', 'ingress-tls'] => {
    'metadata' => {'resourceVersion' => '13'}, 'data' => {'tls.crt' => 'encoded', 'tls.key' => 'encoded'}
  }
}
runner = PreflightRunner.new
certificate_validator = PreflightCertificateValidator.new
preflight = ForemanRelease::ClusterPreflight.new(
  client, runner: runner, certificate_validator: certificate_validator
)
snapshot = preflight.validate!(documents, 'platform')
unless snapshot.fingerprint(documents).match?(/\A[0-9a-f]{64}\z/)
  raise 'valid cluster dependencies did not produce a Secret input fingerprint'
end
validated_certificate_secrets = certificate_validator.calls.map { |arguments| arguments.take(2) }
unless validated_certificate_secrets.include?(%w[platform ingress-ca]) &&
       validated_certificate_secrets.include?(%w[platform ingress-tls])
  raise 'preflight did not validate referenced certificate Secrets'
end
ingress_validation = certificate_validator.calls.find { |arguments| arguments.take(2) == %w[platform ingress-tls] }
unless ingress_validation.last == {
  required_identities: {'tls.crt' => %w[content.example.test foreman.example.test]}
}
  raise 'preflight did not validate the Ingress certificate against its declared DNS names'
end
dry_run = runner.calls.fetch(0)
expected_command = %w[kubectl --namespace platform apply --dry-run=server --filename -]
raise 'preflight did not use a server-side admission dry-run' unless dry_run.first == expected_command
raise 'preflight did not submit the complete rendered manifest' unless dry_run.last.include?('kind: Deployment')

runner.calls.clear
certificate_validator.calls.clear
original_fingerprint = preflight.validate_secrets!(documents, 'platform').fingerprint(documents)
raise 'Secret-only audit unexpectedly ran admission dry-run' unless runner.calls.empty?
unless certificate_validator.calls.map { |arguments| arguments.take(2) }.include?(%w[platform ingress-tls])
  raise 'Secret-only audit did not validate certificate inputs'
end
client.objects[['platform', 'secret', 'database']]['metadata']['resourceVersion'] = '14'
rotated_fingerprint = preflight.validate_secrets!(documents, 'platform').fingerprint(documents)
raise 'Secret resourceVersion change did not alter the input fingerprint' if rotated_fingerprint == original_fingerprint
client.objects[['platform', 'secret', 'database']]['metadata']['resourceVersion'] = '11'

client.objects[['platform', 'secret', 'database']] = {'metadata' => {'resourceVersion' => '15'}, 'data' => {}}
begin
  preflight.validate!(documents, 'platform')
  raise 'missing Secret key was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('database is missing keys: password')
end

client.objects[['platform', 'secret', 'database']] = {
  'metadata' => {'resourceVersion' => '16'}, 'data' => {'password' => 'encoded'}
}
client.objects.delete([nil, 'ingressclass', 'nginx'])
begin
  preflight.validate!(documents, 'platform')
  raise 'missing IngressClass was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('required ingressclass nginx does not exist')
end

client.objects[[nil, 'ingressclass', 'nginx']] = {'spec' => {'controller' => 'k8s.io/ingress-nginx'}}
client.objects.delete([nil, 'customresourcedefinition', 'prometheusrules.monitoring.coreos.com'])
begin
  preflight.validate!(documents, 'platform')
  raise 'missing PrometheusRule CRD was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('required customresourcedefinition prometheusrules.monitoring.coreos.com')
end

client.objects[[nil, 'customresourcedefinition', 'prometheusrules.monitoring.coreos.com']] = {
  'metadata' => {'name' => 'prometheusrules.monitoring.coreos.com'}
}
client.objects.delete([nil, 'priorityclass', 'foreman-platform-critical'])
begin
  preflight.validate!(documents, 'platform')
  raise 'missing PriorityClass was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('required priorityclass foreman-platform-critical does not exist')
end

client.objects[[nil, 'priorityclass', 'foreman-platform-critical']] = {
  'metadata' => {'name' => 'foreman-platform-critical'}
}
runner.fail = true
begin
  preflight.validate!(documents, 'platform')
  raise 'server-side admission rejection was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('server-side admission dry-run failed')
end

puts 'Operator preflight validates rendered cluster resources and Secret keys.'
