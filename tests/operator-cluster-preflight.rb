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
  ['platform', 'persistentvolumeclaim', 'imported-content'] => {'metadata' => {'name' => 'imported-content'}},
  ['platform', 'serviceaccount', 'external-runtime'] => {'metadata' => {'name' => 'external-runtime'}},
  ['platform', 'secret', 'database'] => {'data' => {'password' => 'encoded'}},
  ['platform', 'secret', 'ingress-ca'] => {'data' => {'ca.crt' => 'encoded'}},
  ['platform', 'secret', 'ingress-tls'] => {'data' => {'tls.crt' => 'encoded', 'tls.key' => 'encoded'}}
}
preflight = ForemanRelease::ClusterPreflight.new(client)
raise 'valid cluster dependencies were rejected' unless preflight.validate!(documents, 'platform')

client.objects[['platform', 'secret', 'database']] = {'data' => {}}
begin
  preflight.validate!(documents, 'platform')
  raise 'missing Secret key was accepted'
rescue ForemanRelease::InvalidRelease => error
  raise unless error.message.include?('database is missing keys: password')
end

client.objects[['platform', 'secret', 'database']] = {'data' => {'password' => 'encoded'}}
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

puts 'Operator preflight validates rendered cluster resources and Secret keys.'
