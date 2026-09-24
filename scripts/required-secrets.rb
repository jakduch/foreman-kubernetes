#!/usr/bin/env ruby
# frozen_string_literal: true

require 'set'
require 'yaml'

documents = YAML.load_stream($stdin.read).compact.select { |document| document.is_a?(Hash) }
rendered_secrets = documents.each_with_object(Set.new) do |document, names|
  name = document.dig('metadata', 'name')
  names << name if document['kind'] == 'Secret' && name
end
references = Hash.new { |secrets, name| secrets[name] = Set.new }

add_reference = lambda do |reference, name_key:, key_key: nil|
  next unless reference.is_a?(Hash)
  next if reference['optional'] == true

  name = reference[name_key].to_s
  next if name.empty?

  references[name]
  key = key_key && reference[key_key].to_s
  references[name] << key unless key.nil? || key.empty?
end

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
  pod_spec = pod_spec_for.call(document)
  next unless pod_spec.is_a?(Hash)

  Array(pod_spec['imagePullSecrets']).each do |secret|
    add_reference.call(secret, name_key: 'name')
  end

  %w[initContainers containers ephemeralContainers].each do |container_type|
    Array(pod_spec[container_type]).each do |container|
      Array(container['envFrom']).each do |source|
        add_reference.call(source['secretRef'], name_key: 'name')
      end
      Array(container['env']).each do |environment|
        add_reference.call(
          environment.dig('valueFrom', 'secretKeyRef'),
          name_key: 'name',
          key_key: 'key'
        )
      end
    end
  end

  Array(pod_spec['volumes']).each do |volume|
    secret = volume['secret']
    add_reference.call(secret, name_key: 'secretName')
    Array(secret && secret['items']).each do |item|
      references[secret['secretName']] << item['key'] if item['key']
    end unless secret && secret['optional'] == true

    Array(volume.dig('projected', 'sources')).each do |source|
      projected_secret = source['secret']
      add_reference.call(projected_secret, name_key: 'name')
      Array(projected_secret && projected_secret['items']).each do |item|
        references[projected_secret['name']] << item['key'] if item['key']
      end unless projected_secret && projected_secret['optional'] == true
    end
  end
end

rendered_secrets.each { |name| references.delete(name) }
references.sort.each do |name, keys|
  puts "#{name}\t#{keys.to_a.sort.join(',')}"
end
