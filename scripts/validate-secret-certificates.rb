#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'pathname'

root = Pathname.new(File.expand_path('..', __dir__))
require root.join('operator/lib/foreman_release/certificate_validator').to_s

namespace, name, keys, minimum_validity = ARGV
abort "usage: #{$PROGRAM_NAME} NAMESPACE SECRET KEYS MINIMUM_VALIDITY_SECONDS" unless minimum_validity

begin
  secret = JSON.parse($stdin.read)
  validator = ForemanRelease::CertificateValidator.new(
    minimum_validity_seconds: Integer(minimum_validity, 10)
  )
  validator.validate_secret!(namespace, name, secret, keys.to_s.split(',').reject(&:empty?))
rescue JSON::ParserError, ArgumentError, ForemanRelease::InvalidRelease => error
  warn error.message
  exit 1
end
