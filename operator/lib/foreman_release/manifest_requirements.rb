# frozen_string_literal: true

require 'set'

module ForemanRelease
  class ManifestRequirements
    def initialize(documents)
      @documents = Array(documents).select { |document| document.is_a?(Hash) }
      @rendered = @documents.each_with_object(Set.new) do |document, identities|
        name = document.dig('metadata', 'name')
        identities << [document['kind'], name] if document['kind'] && name
      end
    end

    def cluster_resources
      requirements = Set.new
      @documents.each do |document|
        add_document_requirement(requirements, document)
        pod_spec = pod_spec_for(document)
        next unless pod_spec.is_a?(Hash)

        service_account = pod_spec['serviceAccountName'].to_s
        if !service_account.empty? && !@rendered.include?(['ServiceAccount', service_account])
          requirements << ['ServiceAccount', service_account]
        end
        Array(pod_spec['volumes']).each do |volume|
          claim_name = volume.dig('persistentVolumeClaim', 'claimName').to_s
          next if claim_name.empty? || @rendered.include?(['PersistentVolumeClaim', claim_name])

          requirements << ['PersistentVolumeClaim', claim_name]
        end
      end
      requirements.to_a.sort
    end

    def secrets
      references = Hash.new { |secrets, name| secrets[name] = Set.new }
      rendered_secrets = @documents.each_with_object(Set.new) do |document, names|
        name = document.dig('metadata', 'name')
        names << name if document['kind'] == 'Secret' && name
      end
      @documents.each do |document|
        add_ingress_secrets(references, document)
        pod_spec = pod_spec_for(document)
        next unless pod_spec.is_a?(Hash)

        add_pod_secrets(references, pod_spec)
      end
      rendered_secrets.each { |name| references.delete(name) }
      references.transform_values { |keys| keys.to_a.sort }.sort.to_h
    end

    private

    def add_document_requirement(requirements, document)
      case document['kind']
      when 'HorizontalPodAutoscaler'
        metrics = Array(document.dig('spec', 'metrics')).map { |metric| metric['type'] }
        requirements << ['APIService', 'v1beta1.metrics.k8s.io', 'Available'] unless (metrics & %w[Resource ContainerResource]).empty?
      when 'PersistentVolumeClaim'
        storage_class = document.dig('spec', 'storageClassName').to_s
        requirements << (storage_class.empty? ? ['DefaultStorageClass', ''] : ['StorageClass', storage_class])
      when 'Ingress'
        ingress_class = document.dig('spec', 'ingressClassName').to_s
        return if ingress_class.empty?

        requirement = ['IngressClass', ingress_class]
        controller = document.dig('metadata', 'annotations', 'foreman-kubernetes.io/required-ingress-controller').to_s
        requirement << controller unless controller.empty?
        requirements << requirement
      end
    end

    def add_ingress_secrets(references, document)
      return unless document['kind'] == 'Ingress'

      Array(document.dig('spec', 'tls')).each do |tls|
        name = tls['secretName'].to_s
        references[name].merge(%w[tls.crt tls.key]) unless name.empty?
      end
      client_ca_reference = document.dig('metadata', 'annotations', 'nginx.ingress.kubernetes.io/auth-tls-secret').to_s
      return if client_ca_reference.empty?

      references[client_ca_reference.split('/', 2).last] << 'ca.crt'
    end

    def add_pod_secrets(references, pod_spec)
      Array(pod_spec['imagePullSecrets']).each do |secret|
        add_reference(references, secret, name_key: 'name')
      end
      %w[initContainers containers ephemeralContainers].each do |container_type|
        Array(pod_spec[container_type]).each do |container|
          Array(container['envFrom']).each do |source|
            add_reference(references, source['secretRef'], name_key: 'name')
          end
          Array(container['env']).each do |environment|
            add_reference(
              references, environment.dig('valueFrom', 'secretKeyRef'),
              name_key: 'name', key_key: 'key'
            )
          end
        end
      end
      Array(pod_spec['volumes']).each do |volume|
        add_volume_secret(references, volume['secret'], name_key: 'secretName')
        Array(volume.dig('projected', 'sources')).each do |source|
          add_volume_secret(references, source['secret'], name_key: 'name')
        end
      end
    end

    def add_volume_secret(references, secret, name_key:)
      add_reference(references, secret, name_key: name_key)
      return unless secret.is_a?(Hash) && secret['optional'] != true

      name = secret[name_key].to_s
      Array(secret['items']).each do |item|
        references[name] << item['key'] if !name.empty? && item['key']
      end
    end

    def add_reference(references, reference, name_key:, key_key: nil)
      return unless reference.is_a?(Hash) && reference['optional'] != true

      name = reference[name_key].to_s
      return if name.empty?

      references[name]
      key = key_key && reference[key_key].to_s
      references[name] << key unless key.nil? || key.empty?
    end

    def pod_spec_for(document)
      case document['kind']
      when 'Pod'
        document['spec']
      when 'Deployment', 'DaemonSet', 'ReplicaSet', 'StatefulSet', 'Job'
        document.dig('spec', 'template', 'spec')
      when 'CronJob'
        document.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
      end
    end
  end
end
