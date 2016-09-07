#!/usr/bin/env ruby
# This code verifies the integrity of a FoundationDB Backup.
# Written by: Courtney Cotton 12-04-15, Updated: 1-21-2016
# Resources: http://docs.datadoghq.com/ja/api/

# Libraries
require 'rubygems'
require 'fileutils'
require 'logger'
require 'dogapi'
require 'yaml'

# Potential bit of code to have it automatically create + destroy log each run.
# file = File.open('fdbbackupcheck.log', File::WRONLY | File::APPEND | File::CREAT)
# logger = Logger.new(file)
@logger = Logger.new('fdbbackupcheck.log')

# Accepts errors, and generates JSON format for Datadog E-mail API
def send_dd_email(title, text, priority, *tags, alert_type)
  File.exist?('./fdb.dd.yaml') ?
    config = YAML.load_file('./fdb.dd.yaml') :
    @logger.fatal("Could not locate config file: ./fdb.dd.yaml") && abort

  # Authorization for DataDog
  api_key = config['datadog']['api_key']
  app_key = config['datadog']['app_key']
  dog = Dogapi::Client.new(api_key, app_key)

  dog.emit_event(Dogapi::Event.new(
    "#{text}",
    :msg_title => "#{title}",
    :priority => "#{priority}",
    :tags => "#{tags}",
    :alert_type => "#{alert_type}"
     ))
  @logger.info "Backup result information sent to Datadog."
end

# Run a check to verify if the backup_agent proccess is running.
# Note: This should always be running, backups cannot be performed without
#  the backup agent. This should trigger an alert if it's unable to be found.
`ps aux | grep backup_agent | grep -v grep`
if fdb_status = $?.exitstatus != 0
    send_dd_email(
      "Unable to find the backup_agent service process",
      "FDB Backup Error",
      "normal",
      "fdb, production, backup",
      "error"
    )
    @logger.error "Backup Agent not running. Notifying Datadog."
    exit 1
end

# Verify backup folder has proper permissions.
backup_dir = "/etc/foundationdb/restore"

FileUtils.chown 'foundationdb', 'foundationdb', backup_dir

# Run FDB Backup & ship it off to AWS S3
clusterfile  = "/etc/foundationdb/fdb.cluster"
bucket_name = "YER_s3_Bucket"

timestamp = Time.new.strftime("%m-%d-%Y-%H-%M")
output = []

IO.popen("fdbbackup -C #{clusterfile} start -d #{backup_dir} && fdbbackup wait").each do |line|
  did_backup_complete = true if line.match("complete")
  if did_backup_complete == true && if $?.success?
    p line.chomp
    output << line.chomp
    send_dd_email(
      "FDB Backup Success",
      "#{output}",
      "low",
      "fdb, production, backup",
      "success"
    )
    @logger.info "Backup successful. Alerting Datadog to the success."
    @logger.info "Shipping to AWS S3"
    `tar -czf #{backup_dir}/#{timestamp}.tar -C #{backup_dir} .`
    `aws s3 cp #{backup_dir}/#{timestamp}.tar #{bucket_name}/latest/foundationdb-latest.tar --region us-west-2`
    `aws s3 cp #{backup_dir}/#{timestamp}.tar #{bucket_name}/intervals/ --region us-west-2`
    @logger.info "Finished shipping. Package delivered."
  else
    p line.chomp
    output << line.chomp
    send_dd_email(
      "#{output}",
      "FDB Backup Error",
      "normal",
      "fdb, production, backup",
      "error"
    )
    @logger.error "Backup failed. Let chaos reign."
  end
  end
end

# Time for a bit of cleanup. Cleanup. Everyone loves to cleanup!
@logger.info "Removing files under #{backup_dir}."
FileUtils.rm_rf(Dir.glob(backup_dir + '/*'))
@logger.close
