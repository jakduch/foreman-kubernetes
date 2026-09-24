# frozen_string_literal: true

heartbeat_path = ENV.fetch('KATELLO_EVENT_DAEMON_HEARTBEAT')
heartbeat_interval = Integer(ENV.fetch('KATELLO_EVENT_DAEMON_HEARTBEAT_INTERVAL'), 10)

FileUtils.rm_f(heartbeat_path)
Katello::EventDaemon::Runner.start

at_exit { FileUtils.rm_f(heartbeat_path) }

loop do
  status = Katello::EventDaemon::Runner.service_status(:katello_events)

  if status&.dig(:running)
    temporary_path = "#{heartbeat_path}.tmp"
    File.write(temporary_path, Time.now.to_i)
    File.rename(temporary_path, heartbeat_path)
  else
    FileUtils.rm_f(heartbeat_path)
  end

  sleep heartbeat_interval
end
