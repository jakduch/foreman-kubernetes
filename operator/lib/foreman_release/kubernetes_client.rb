# frozen_string_literal: true

require 'base64'
require 'json'
require_relative 'command_runner'

module ForemanRelease
  class KubernetesClient
    RESOURCE = 'foremanreleases.platform.theforeman.org'

    def initialize(runner: CommandRunner.new)
      @runner = runner
    end

    def releases(namespace)
      response = @runner.run(
        'kubectl', '--namespace', namespace, 'get', RESOURCE, '--output=json'
      )
      JSON.parse(response).fetch('items')
    end

    def release(namespace, name)
      response = @runner.run(
        'kubectl', '--namespace', namespace, 'get', RESOURCE, name, '--output=json'
      )
      JSON.parse(response)
    end

    def secret_value(namespace, name, key)
      response = @runner.run(
        'kubectl', '--namespace', namespace, 'get', 'secret', name, '--output=json'
      )
      encoded = JSON.parse(response).dig('data', key)
      raise KeyError, "Secret #{namespace}/#{name} has no key #{key}" unless encoded

      Base64.strict_decode64(encoded)
    rescue ArgumentError
      raise ArgumentError, "Secret #{namespace}/#{name} key #{key} is not valid base64"
    end

    def write_status(resource, status)
      metadata = resource.fetch('metadata')
      resource_version = metadata.fetch('resourceVersion')
      patch = [
        {
          'op' => 'test',
          'path' => '/metadata/resourceVersion',
          'value' => resource_version
        },
        {
          'op' => 'add',
          'path' => '/status',
          'value' => status
        }
      ]
      response = @runner.run(
        'kubectl', '--namespace', metadata.fetch('namespace'),
        'patch', RESOURCE, metadata.fetch('name'),
        '--subresource=status', '--type=json', '--patch', JSON.generate(patch),
        '--output=json'
      )
      JSON.parse(response)
    end
  end
end
