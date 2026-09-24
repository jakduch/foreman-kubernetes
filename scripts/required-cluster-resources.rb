#!/usr/bin/env ruby
# frozen_string_literal: true

require 'set'
require 'yaml'

documents = YAML.load_stream($stdin.read).compact.select { |document| document.is_a?(Hash) }
rendered = documents.each_with_object(Set.new) do |document, identities|
  name = document.dig('metadata', 'name')
  identities << [document['kind'], name] if document['kind'] && name
end
requirements = Set.new

pod_spec_for = lambda do |document|
  case document['kind']
  when 'Pod'
    document['spec']
  when 'Deployment', 'DaemonSet', 'ReplicaSet', 'StatefulSet', 'Job'
    document.dig('spec', 'template', 'spec')
  when 'CronJob'
    document.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
  end
end

documents.each do |document|
  case document['kind']
  when 'PersistentVolumeClaim'
    storage_class = document.dig('spec', 'storageClassName').to_s
    if storage_class.empty?
      requirements << ['DefaultStorageClass', '']
    else
      requirements << ['StorageClass', storage_class]
    end
  when 'Ingress'
    ingress_class = document.dig('spec', 'ingressClassName').to_s
    requirements << ['IngressClass', ingress_class] unless ingress_class.empty?
  end

  pod_spec = pod_spec_for.call(document)
  next unless pod_spec.is_a?(Hash)

  service_account = pod_spec['serviceAccountName'].to_s
  if !service_account.empty? && !rendered.include?(['ServiceAccount', service_account])
    requirements << ['ServiceAccount', service_account]
  end

  Array(pod_spec['volumes']).each do |volume|
    claim_name = volume.dig('persistentVolumeClaim', 'claimName').to_s
    next if claim_name.empty? || rendered.include?(['PersistentVolumeClaim', claim_name])

    requirements << ['PersistentVolumeClaim', claim_name]
  end
end

requirements.sort.each { |kind, name| puts "#{kind}\t#{name}" }
