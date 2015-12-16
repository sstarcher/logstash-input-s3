# encoding: utf-8
require "logstash/inputs/base"
require "logstash/namespace"
require "logstash/plugin_mixins/aws_config"
require "time"
require "tmpdir"
require "stud/interval"
require "stud/temporary"

# Stream events from files from a S3 bucket.
#
# Each line from each file generates an event.
# Files ending in `.gz` are handled as gzip'ed files.
class LogStash::Inputs::S3 < LogStash::Inputs::Base
  include LogStash::PluginMixins::AwsConfig

  config_name "s3"

  default :codec, "plain"

  # DEPRECATED: The credentials of the AWS account used to access the bucket.
  # Credentials can be specified:
  # - As an ["id","secret"] array
  # - As a path to a file containing AWS_ACCESS_KEY_ID=... and AWS_SECRET_ACCESS_KEY=...
  # - In the environment, if not set (using variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY)
  config :credentials, :validate => :array, :default => [], :deprecated => "This only exists to be backwards compatible. This plugin now uses the AwsConfig from PluginMixins"

  # The name of the S3 bucket.
  config :bucket, :validate => :string, :required => true

  # The AWS region for your bucket.
  config :region_endpoint, :validate => ["us-east-1", "us-west-1", "us-west-2",
                                "eu-west-1", "ap-southeast-1", "ap-southeast-2",
                                "ap-northeast-1", "sa-east-1", "us-gov-west-1"], :deprecated => "This only exists to be backwards compatible. This plugin now uses the AwsConfig from PluginMixins"

  # If specified, the prefix of filenames in the bucket must match (not a regexp)
  config :prefix, :validate => :string, :default => nil

  # Where to write the since database (keeps track of the date
  # the last handled file was added to S3). The default will write
  # sincedb files to some path matching "$HOME/.sincedb*"
  # Should be a path with filename not just a directory.
  config :sincedb_path, :validate => :string, :default => nil

  # Name of a S3 bucket to backup processed files to.
  config :backup_to_bucket, :validate => :string, :default => nil

  # Append a prefix to the key (full path including file name in s3) after processing.
  # If backing up to another (or the same) bucket, this effectively lets you
  # choose a new 'folder' to place the files in
  config :backup_add_prefix, :validate => :string, :default => nil

  # Path of a local directory to backup processed files to.
  config :backup_to_dir, :validate => :string, :default => nil

  # Whether to delete processed files from the original bucket.
  config :delete, :validate => :boolean, :default => false

  # Interval to wait between to check the file list again after a run is finished.
  # Value is in seconds.
  config :interval, :validate => :number, :default => 60

  # Ruby style regexp of keys to exclude from the bucket
  config :exclude_pattern, :validate => :string, :default => nil

  # Set the directory where logstash will store the tmp files before processing them.
  # default to the current OS temporary directory in linux /tmp/logstash
  config :temporary_directory, :validate => :string, :default => File.join(Dir.tmpdir, "logstash")

  # Set the number of threads that will work on the internal queue of files found to match your criteria
  config :worker_count, :validate => :number, :default => 4

  public
  def register
    require "fileutils"
    require "digest/md5"
    require "aws-sdk-resources"
    require "thread"

    @region = get_region

    @logger.info("Registering s3 input", :bucket => @bucket, :region => @region)

    s3 = get_s3object

    @s3bucket = s3.bucket(@bucket)

    unless @backup_to_bucket.nil?
      @backup_bucket = s3.bucket(@backup_to_bucket)
      begin
        s3.client.head_bucket({ :bucket => @backup_to_bucket})
      rescue Aws::S3::Errors::NoSuchBucket
        s3.create_bucket({ :bucket => @backup_to_bucket})
      end
    end

    unless @backup_to_dir.nil?
      Dir.mkdir(@backup_to_dir, 0700) unless File.exists?(@backup_to_dir)
    end

    FileUtils.mkdir_p(@temporary_directory) unless Dir.exist?(@temporary_directory)
  end # def register

  public
  def run(queue)
    @current_thread = Thread.current
    Stud.interval(@interval) do
      process_files(queue)
    end
  end # def run

  public
  def list_new_files
    objects = {}
    work_q = Queue.new

    @s3bucket.objects(:prefix => @prefix).each do |log|
      unless ignore_filename?(log.key)
        @logger.debug("S3 input: Found key", :key => log.key)
        # is the file we are looking at newer than the last file we processed on the last run?
        if sincedb.newer?(log.last_modified)
          objects[log.key] = log.last_modified
          @logger.debug("S3 input: Adding to objects[]", :key => log.key)
          @logger.debug("S3 input: objects[] length is: ", :length => objects.length)
        end
      end
    end
    objects.keys.sort {|a,b| objects[a] <=> objects[b]}
    objects.each do |key, last_mod|
        work_q.push(key)
        @logger.debug("S3 input: Putting object on the queue", :queue_size => work_q.size, :object => key)
    end
    return work_q
  end # def fetch_new_files

  public
  def backup_to_bucket(object)
    unless @backup_to_bucket.nil?
      backup_key = "#{@backup_add_prefix}#{object.key}"
      @backup_bucket.object(backup_key).copy_from(:copy_source => "#{object.bucket_name}/#{object.key}")
      if @delete
        object.delete()
      end
    end
  end

  public
  def backup_to_dir(filename)
    unless @backup_to_dir.nil?
      FileUtils.cp(filename, @backup_to_dir)
    end
  end

  public
  def process_files(queue)
    work_q = list_new_files
    workers = (0...@worker_count).map do
      Thread.new do
        begin
          while key = work_q.pop(true)
            @logger.debug("S3 input processing", :bucket => @bucket, :key => key)

            lastmod = @s3bucket.object(key).last_modified

            process_log(queue, key)

            sincedb.write(lastmod)
          end
        rescue ThreadError
        end
      end
    end; "ok"
    workers.map(&:join); "ok"
  end # def process_files

  public
  def stop
    # @current_thread is initialized in the `#run` method, 
    # this variable is needed because the `#stop` is a called in another thread 
    # than the `#run` method and requiring us to call stop! with a explicit thread.
    Stud.stop!(@current_thread)
  end

  public
  def aws_service_endpoint(region)
    region_to_use = get_region

    return {
      :s3_endpoint => region_to_use == 'us-east-1' ?
        's3.amazonaws.com' : "s3-#{region_to_use}.amazonaws.com"
    }
  end

  private

  # Read the content of the local file
  #
  # @param [Queue] Where to push the event
  # @param [String] Which file to read from
  # @return [Boolean] True if the file was completely read, false otherwise.
  def process_local_log(queue, filename)
    @logger.debug('Processing file', :filename => filename)

    metadata = {}
    # Currently codecs operates on bytes instead of stream.
    # So all IO stuff: decompression, reading need to be done in the actual
    # input and send as bytes to the codecs.
    read_file(filename) do |line|
      if stop?
        @logger.warn("Logstash S3 input, stop reading in the middle of the file, we will read it again when logstash is started")
        return false
      end

      @codec.decode(line) do |event|
        # We are making an assumption concerning cloudfront
        # log format, the user will use the plain or the line codec
        # and the message key will represent the actual line content.
        # If the event is only metadata the event will be drop.
        # This was the behavior of the pre 1.5 plugin.
        #
        # The line need to go through the codecs to replace
        # unknown bytes in the log stream before doing a regexp match or
        # you will get a `Error: invalid byte sequence in UTF-8'
        if event_is_metadata?(event)
          @logger.debug('Event is metadata, updating the current cloudfront metadata', :event => event)
          update_metadata(metadata, event)
        else
          decorate(event)

          event["cloudfront_version"] = metadata[:cloudfront_version] unless metadata[:cloudfront_version].nil?
          event["cloudfront_fields"]  = metadata[:cloudfront_fields] unless metadata[:cloudfront_fields].nil?

          queue << event
        end
      end
    end

    return true
  end # def process_local_log

  private
  def event_is_metadata?(event)
    line = event['message']
    unless line.nil?
      version_metadata?(line) || fields_metadata?(line)
    else
      false
    end
  end

  private
  def version_metadata?(line)
    line.start_with?('#Version: ')
  end

  private
  def fields_metadata?(line)
    line.start_with?('#Fields: ')
  end

  private 
  def update_metadata(metadata, event)
    line = event['message'].strip

    if version_metadata?(line)
      metadata[:cloudfront_version] = line.split(/#Version: (.+)/).last
    end

    if fields_metadata?(line)
      metadata[:cloudfront_fields] = line.split(/#Fields: (.+)/).last
    end
  end

  private
  def read_file(filename, &block)
    if gzip?(filename) 
      read_gzip_file(filename, block)
    else
      read_plain_file(filename, block)
    end
  end

  def read_plain_file(filename, block)
    File.open(filename, 'rb') do |file|
      file.each(&block)
    end
  end

  private
  def read_gzip_file(filename, block)
    begin
      Zlib::GzipReader.open(filename) do |decoder|
        decoder.each_line { |line| block.call(line) }
      end
    rescue Zlib::Error, Zlib::GzipFile::Error => e
      @logger.error("Gzip codec: We cannot uncompress the gzip file", :filename => filename)
      raise e
    end
  end

  private
  def gzip?(filename)
    filename.end_with?('.gz')
  end
  
  private
  def sincedb 
    @sincedb ||= if @sincedb_path.nil?
                    @logger.info("Using default generated file for the sincedb", :filename => sincedb_file)
                    SinceDB::File.new(sincedb_file)
                  else
                    @logger.info("Using the provided sincedb_path",
                                 :sincedb_path => @sincedb_path)
                    SinceDB::File.new(@sincedb_path)
                  end
  end

  private
  def sincedb_file
    File.join(ENV["HOME"], ".sincedb_" + Digest::MD5.hexdigest("#{@bucket}+#{@prefix}"))
  end

  private
  def ignore_filename?(filename)
    if @prefix == filename
      return true
    elsif filename.end_with?("/")
      return true
    elsif (@backup_add_prefix && @backup_to_bucket == @bucket && filename =~ /^#{backup_add_prefix}/)
      return true
    elsif @exclude_pattern.nil?
      return false
    elsif filename =~ Regexp.new(@exclude_pattern)
      return true
    else
      return false
    end
  end

  private
  def process_log(queue, key)
    object = @s3bucket.object(key)

    filename = File.join(temporary_directory, File.basename(key))
    download_remote_file(object, filename)

    process_local_log(queue, filename)

    backup_to_bucket(object)
    backup_to_dir(filename)

    delete_file_from_bucket(object)
    File.delete(filename)
  end

  private
  # Stream the remove file to the local disk
  #
  # @param [S3Object] Reference to the remove S3 objec to download
  # @param [String] The Temporary filename to stream to.
  # @return [Boolean] True if the file was completely downloaded
  def download_remote_file(remote_object, local_filename)
    @logger.debug("S3 input: Download remote file", :remote_key => remote_object.key, :local_filename => local_filename)
    File.open(local_filename, 'wb') do |s3file|
        remote_object.get(:response_target => s3file)
    end
    completed = true

    return completed
  end

  private
  def delete_file_from_bucket(object)
    if @delete and @backup_to_bucket.nil?
      object.delete()
    end
  end

  private
  def get_region
    # TODO: (ph) Deprecated, it will be removed
    if @region_endpoint
      @region_endpoint
    else
      @region
    end
  end

  private
  def get_s3object
    # TODO: (ph) Deprecated, it will be removed
    if @credentials.length == 1
      File.open(@credentials[0]) { |f| f.each do |line|
        unless (/^\#/.match(line))
          if(/\s*=\s*/.match(line))
            param, value = line.split('=', 2)
            param = param.chomp().strip()
            value = value.chomp().strip()
            if param.eql?('AWS_ACCESS_KEY_ID')
              @access_key_id = value
            elsif param.eql?('AWS_SECRET_ACCESS_KEY')
              @secret_access_key = value
            end
          end
        end
      end
      }
    elsif @credentials.length == 2
      @access_key_id = @credentials[0]
      @secret_access_key = @credentials[1]
    end

    if @credentials
      s3 = Aws::S3::Resource.new(
        :access_key_id => @access_key_id,
        :secret_access_key => @secret_access_key,
        :region => @region
      )
    else
      s3 = Aws::S3::Resource.new(aws_options_hash)
    end
  end

  private
  module SinceDB
    class File
      def initialize(file)
        @sincedb_path = file
      end

      def newer?(date)
        date > read
      end

      def read
        if ::File.exists?(@sincedb_path)
          content = ::File.read(@sincedb_path).chomp.strip
          # If the file was created but we didn't have the time to write to it
          return content.empty? ? Time.new(0) : Time.parse(content)
        else
          return Time.new(0)
        end
      end

      def write(since = nil)
        since = Time.now() if since.nil?
        ::File.open(@sincedb_path, 'w') { |file| file.write(since.to_s) }
      end
    end
  end
end # class LogStash::Inputs::S3
