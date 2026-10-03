# frozen_string_literal: true

require 'base64'
require 'digest'
require 'json'
require 'stringio'
require 'tempfile'

USER_LOGIN = 'admin'
REPORT_FILENAME = 'foreman-kubernetes-active-storage-e2e-report.tar.xz'
KATELLO_FILENAME = 'foreman-kubernetes-active-storage-e2e-upload.bin'
AVATAR = Base64.decode64(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII='
).b
REPORT_PAYLOAD = ('foreman-rh-cloud-active-storage-e2e' * 4096).b
KATELLO_PAYLOAD = ('katello-active-storage-staging-e2e' * 65_536).b
AVATAR_FILENAME = "ldap-avatar-#{Digest::SHA256.hexdigest(AVATAR)}.png"

def purge_previous_records
  user = User.unscoped.find_by!(login: USER_LOGIN)
  if user.avatar.attached?
    unless user.avatar.filename.to_s == AVATAR_FILENAME
      raise "Refusing to replace the existing #{USER_LOGIN} avatar"
    end
    User.as_anonymous_admin { user.avatar.purge }
  end
  ForemanInventoryUpload::Report.where(filename: REPORT_FILENAME).find_each do |report|
    report.archive.purge if report.archive.attached?
    report.destroy!
  end
  ActiveStorage::Blob.where(filename: KATELLO_FILENAME).find_each(&:purge)
end

def produce
  # A standalone runner starts after Foreman's Dynflow initializer window.
  # Perform the avatar analysis inline; the web process uses its normal
  # initialized Dynflow adapter in production.
  ActiveJob::Base.queue_adapter = :inline
  purge_previous_records
  user = User.unscoped.find_by!(login: USER_LOGIN)
  User.as_anonymous_admin { user.update_ldap_avatar(AVATAR) }
  raise 'LDAP avatar attachment failed' unless user.reload.avatar.attached?

  organization = Organization.first || raise('Foreman has no organization for the report probe')
  report = ForemanInventoryUpload::Report.create!(
    organization: organization,
    filename: REPORT_FILENAME
  )
  report.archive.attach(
    io: StringIO.new(REPORT_PAYLOAD),
    filename: REPORT_FILENAME,
    content_type: 'application/x-xz',
    identify: false
  )

  staged = Tempfile.create('foreman-kubernetes-katello-upload') do |file|
    file.binmode
    file.write(KATELLO_PAYLOAD)
    file.flush
    action = Actions::Katello::Repository::UploadFiles.allocate
    action.send(
      :stage_files,
      [{path: file.path, filename: KATELLO_FILENAME, content_type: 'application/octet-stream'}]
    ).fetch(0)
  end
  blob = ActiveStorage::Blob.find_signed!(staged.fetch(:blob_signed_id))

  puts JSON.generate(
    phase: 'produce',
    service: blob.service_name,
    avatar_sha256: Digest::SHA256.hexdigest(AVATAR),
    report_sha256: Digest::SHA256.hexdigest(REPORT_PAYLOAD),
    katello_sha256: staged.fetch(:sha256),
    katello_bytes: staged.fetch(:byte_size)
  )
end

def consume
  user = User.unscoped.find_by!(login: USER_LOGIN)
  avatar = user.avatar.download
  raise 'LDAP avatar changed across pods' unless Digest::SHA256.digest(avatar) == Digest::SHA256.digest(AVATAR)

  report = ForemanInventoryUpload::Report.find_by!(filename: REPORT_FILENAME)
  report_payload = report.archive.download
  unless Digest::SHA256.digest(report_payload) == Digest::SHA256.digest(REPORT_PAYLOAD)
    raise 'foreman_rh_cloud report changed across pods'
  end

  blob = ActiveStorage::Blob.find_by!(filename: KATELLO_FILENAME)
  input = {
    file: {
      blob_signed_id: blob.signed_id,
      filename: blob.filename.to_s,
      sha256: Digest::SHA256.hexdigest(KATELLO_PAYLOAD),
      byte_size: KATELLO_PAYLOAD.bytesize,
    },
  }
  action = Actions::Pulp3::Repository::UploadFile.allocate
  action.define_singleton_method(:input) { input }
  katello_payload = nil
  action.send(:with_staged_file) do |file, staged_file|
    katello_payload = file.read
    raise 'Katello staging metadata changed across pods' unless staged_file[:sha256] == Digest::SHA256.hexdigest(katello_payload)
  end
  unless Digest::SHA256.digest(katello_payload) == Digest::SHA256.digest(KATELLO_PAYLOAD)
    raise 'Katello staged upload changed across pods'
  end

  puts JSON.generate(
    phase: 'consume',
    services: [user.avatar.blob.service_name, report.archive.blob.service_name, blob.service_name].uniq,
    avatar_sha256: Digest::SHA256.hexdigest(avatar),
    report_sha256: Digest::SHA256.hexdigest(report_payload),
    katello_sha256: Digest::SHA256.hexdigest(katello_payload),
    katello_bytes: katello_payload.bytesize
  )
ensure
  if user&.avatar&.attached? && user.avatar.filename.to_s == AVATAR_FILENAME
    User.as_anonymous_admin { user.avatar.purge }
  end
  report&.archive&.purge if report&.archive&.attached?
  report&.destroy!
  blob&.purge
end

case ENV.fetch('FOREMAN_KUBERNETES_ACTIVE_STORAGE_PHASE')
when 'produce'
  produce
when 'consume'
  consume
else
  raise 'FOREMAN_KUBERNETES_ACTIVE_STORAGE_PHASE must be produce or consume'
end
