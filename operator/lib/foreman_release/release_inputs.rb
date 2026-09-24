# frozen_string_literal: true

require 'json'
require 'pathname'
require 'yaml'

module ForemanRelease
  class InvalidRelease < StandardError; end

  ReleaseProfiles = Struct.new(
    :name,
    :application_path,
    :execution_proxy_path,
    keyword_init: true
  )
  ValuesBundle = Struct.new(:application, :execution_proxy, keyword_init: true)

  class ReleaseCatalog
    def self.load(root)
      root_path = Pathname.new(root).realpath
      manifest = JSON.parse(root_path.join('compatibility/release-sets.json').read)
      new(root: root_path, manifest: manifest)
    end

    def initialize(root:, manifest:)
      @root = Pathname.new(root).realpath
      @sets = manifest.fetch('sets')
    end

    def resolve(name, allow_candidate:)
      release_set = @sets[name]
      raise InvalidRelease, "unknown compatibility set: #{name}" unless release_set

      status = release_set.fetch('status')
      case status
      when 'supported'
        nil
      when 'candidate'
        raise InvalidRelease, "compatibility set #{name} is still a candidate" unless allow_candidate
      when 'retired'
        raise InvalidRelease, "compatibility set #{name} is retired"
      else
        raise InvalidRelease, "compatibility set #{name} has unsupported status #{status}"
      end

      application_path = profile_path(release_set.fetch('applicationProfile'))
      execution_path = profile_path(release_set.fetch('executionProxyProfile'))
      application = load_mapping(application_path)
      execution = load_mapping(execution_path)

      unless application.dig('platform', 'compatibilitySet') == name
        raise InvalidRelease, "application profile identity does not match #{name}"
      end
      unless execution['compatibilitySet'] == name
        raise InvalidRelease, "execution proxy profile identity does not match #{name}"
      end

      %w[foreman candlepin pulp].each do |component|
        digest_pinned!(name, component, application.fetch(component).fetch('image'))
      end
      digest_pinned!(name, 'execution proxy', execution.fetch('image'))

      ReleaseProfiles.new(
        name: name,
        application_path: application_path.to_s,
        execution_proxy_path: execution_path.to_s
      )
    end

    private

    def profile_path(relative_path)
      candidate = @root.join(relative_path)
      raise InvalidRelease, "profile does not exist: #{relative_path}" unless candidate.file?

      path = candidate.realpath
      unless path.to_s.start_with?("#{@root}/")
        raise InvalidRelease, "profile escapes the controller image: #{relative_path}"
      end

      path
    end

    def load_mapping(path)
      value = YAML.safe_load(path.read, permitted_classes: [], permitted_symbols: [], aliases: false)
      raise InvalidRelease, "profile is not a YAML mapping: #{path}" unless value.is_a?(Hash)

      value
    rescue Psych::Exception => error
      raise InvalidRelease, "profile is invalid YAML: #{path}: #{error.message}"
    end

    def digest_pinned!(set_name, component, image)
      reference = "#{image.fetch('repository')}:#{image.fetch('tag')}"
      return if reference.match?(/@sha256:[0-9a-f]{64}\z/)

      raise InvalidRelease, "#{set_name} #{component} image is not digest-pinned"
    end
  end

  class ValuesReader
    def initialize(kubernetes_client)
      @kubernetes_client = kubernetes_client
    end

    def read(resource)
      namespace = resource.dig('metadata', 'namespace')
      raise InvalidRelease, 'ForemanRelease has no namespace' if namespace.to_s.empty?

      ValuesBundle.new(
        application: read_reference(namespace, resource.dig('spec', 'application', 'valuesSecretRef')),
        execution_proxy: read_reference(namespace, resource.dig('spec', 'executionProxy', 'valuesSecretRef'))
      )
    end

    private

    def read_reference(namespace, reference)
      raise InvalidRelease, 'values Secret reference is missing' unless reference

      content = @kubernetes_client.secret_value(
        namespace,
        reference.fetch('name'),
        reference.fetch('key')
      )
      value = YAML.safe_load(content, permitted_classes: [], permitted_symbols: [], aliases: false)
      raise InvalidRelease, 'values Secret key must contain a YAML mapping' unless value.is_a?(Hash)

      content
    rescue KeyError, ArgumentError, Psych::Exception => error
      raise InvalidRelease, error.message
    end
  end
end
