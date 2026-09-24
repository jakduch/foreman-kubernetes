# frozen_string_literal: true

require 'fileutils'
require 'sidekiq'

readiness_file = ENV.fetch('DYNFLOW_READINESS_FILE')
FileUtils.rm_f(readiness_file)

remove_readiness = -> { FileUtils.rm_f(readiness_file) }

Sidekiq.configure_server do |config|
  config.on(:startup) do
    FileUtils.mkdir_p(File.dirname(readiness_file))
    temporary = "#{readiness_file}.#{Process.pid}"
    File.write(temporary, "#{Process.pid}\n")
    File.rename(temporary, readiness_file)
  end
  config.on(:quiet, &remove_readiness)
  config.on(:shutdown, &remove_readiness)
end
