# frozen_string_literal: true

require_relative 'command_runner'
require_relative 'manifest_requirements'
require_relative 'release_inputs'

module ForemanRelease
  class ClusterPreflight
    DEFAULT_STORAGE_ANNOTATIONS = %w[
      storageclass.kubernetes.io/is-default-class
      storageclass.beta.kubernetes.io/is-default-class
    ].freeze

    def initialize(kubernetes_client)
      @kubernetes_client = kubernetes_client
    end

    def validate!(documents, namespace)
      requirements = ManifestRequirements.new(documents)
      requirements.cluster_resources.each do |kind, name, contract|
        validate_resource!(namespace, kind, name, contract)
      end
      requirements.secrets.each do |name, keys|
        secret = required_resource(namespace, 'secret', name)
        missing = keys.reject { |key| secret.fetch('data', {}).key?(key) }
        raise InvalidRelease, "Secret #{namespace}/#{name} is missing keys: #{missing.join(', ')}" unless missing.empty?
      end
      true
    end

    private

    def validate_resource!(namespace, kind, name, contract)
      case kind
      when 'DefaultStorageClass'
        classes = @kubernetes_client.resources(nil, 'storageclasses')
        found = classes.any? do |storage_class|
          annotations = storage_class.dig('metadata', 'annotations') || {}
          DEFAULT_STORAGE_ANNOTATIONS.any? { |annotation| annotations[annotation] == 'true' }
        end
        raise InvalidRelease, 'a rendered PVC requires a default StorageClass, but none is configured' unless found
      when 'StorageClass'
        required_resource(nil, 'storageclass', name)
      when 'IngressClass'
        ingress_class = required_resource(nil, 'ingressclass', name)
        if !contract.to_s.empty? && ingress_class.dig('spec', 'controller') != contract
          raise InvalidRelease, "IngressClass #{name} is not managed by #{contract}"
        end
      when 'APIService'
        api_service = required_resource(nil, 'apiservice', name)
        if contract == 'Available' && !condition_true?(api_service, 'Available')
          raise InvalidRelease, "APIService #{name} is not Available"
        end
      when 'CustomResourceDefinition'
        required_resource(nil, 'customresourcedefinition', name)
      when 'PriorityClass'
        required_resource(nil, 'priorityclass', name)
      when 'PersistentVolumeClaim', 'ServiceAccount'
        required_resource(namespace, kind.downcase, name)
      else
        raise InvalidRelease, "unsupported preflight resource kind: #{kind}"
      end
    end

    def required_resource(namespace, type, name)
      @kubernetes_client.resource(namespace, type, name)
    rescue CommandError
      scope = namespace ? "#{namespace}/" : ''
      raise InvalidRelease, "required #{type} #{scope}#{name} does not exist"
    end

    def condition_true?(resource, type)
      Array(resource.dig('status', 'conditions')).any? do |condition|
        condition['type'] == type && condition['status'] == 'True'
      end
    end
  end
end
