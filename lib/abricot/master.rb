require 'abricot'
require 'thor/core_ext/hash_with_indifferent_access'

trap(:INT) { exit }

class Abricot::Master
  class JobFailure < RuntimeError; end
  class NotEnoughSlaves < RuntimeError; end

  class Signal
    def initialize
      @signal_mutex = Mutex.new
      @signal_cvar = ConditionVariable.new
    end

    def signal!
      @signal_mutex.synchronize { @signal_cvar.broadcast }
    end

    def wait_until(&block)
      @signal_mutex.synchronize do
        loop do
          break if block.call
          @signal_cvar.wait(@signal_mutex)
        end
      end
    end
  end

  attr_accessor :redis, :redis_wait, :jobs
  attr_accessor :wait_loop_running_signal, :wait_loop_running, :redraw_mutex

  def initialize(options={})
    @redis = Redis.new(:url => (options[:redis] || ENV['REDIS_URL']))
    @redis_wait = Redis.new(:url => (options[:redis] || ENV['REDIS_URL']))
    @jobs = {}
    @wait_loop_running_signal = Signal.new
    @redraw_mutex = Mutex.new
    Thread.new { wait_loop }

    at_exit do
      STDERR.print "\033[3D"
      self.kill_all_jobs
    end
  end

  def num_workers_available(tag)
    redis.pubsub('numsub', "abricot:slave_control:#{tag}").last.to_i
  end

  def exec(*args)
    @wait_loop_running_signal.wait_until  { @wait_loop_running }

    options = args.last.is_a?(Hash) ? args.pop : {}
    options = options.dup

    options[:args] ||= args
    options[:multi] = @multi
    job = Job.new(self, options)
    @jobs[job.id] = job
    job.async_exec
    @multi.add_job(job) if @multi
    job.wait unless @multi || options[:async]
    job
  end

  def multi(options={}, &block)
    @multi = Multi.new(self)
    yield
    options[:async] ?  @multi : @multi.wait
  rescue Exception
    begin
      @multi.kill
    rescue
    end
    raise
  ensure
    @multi.finalize unless options[:async]
    @multi = nil
  end

  def kill_all_jobs
    redis.pipelined { jobs.values.each(&:kill) }
  end

  def kill_all
    Thread.new { redis.publish('abricot:slave_control:_all_', {'type' => 'killall'}.to_json) }.join
  end

  def get_job_from_channel(channel)
    @jobs[$1] if channel =~ /^abricot:job:(.*):progress$/
  end

  def wait_loop
    @redis_wait.subscribe("abricot:job:dummy") do |on|
      on.subscribe do |channel|
        @wait_loop_running = true
        @wait_loop_running_signal.signal!

        job = get_job_from_channel(channel)
        job.on_progress_subscribe if job
        redraw_progress
      end

      on.message do |channel, message|
        job = get_job_from_channel(channel)
        job.on_progress_message(message) if job
        redraw_progress
      end
    end
  rescue Exception => e
    STDERR.puts e
    STDERR.puts e.backtrace.join("\n")
    exit 1
  end

  def redraw_progress
    @redraw_mutex.synchronize do
      if @last_num_printed_lines.to_i > 0
        STDERR.print "\033[#{@last_num_printed_lines}A" # Move up
      end

      jobs.values.each do |job|
        status = case job.status
        when :idle     then "\033[1;33m---> #{job.name}..."
        when :started  then "\033[1;33m---> #{job.name}... starting (#{job.num_started}/#{job.num_workers})"
        when :running  then "\033[1;33m---> #{job.name}... running (#{job.num_completed}/#{job.num_workers})"
        when :success  then "\033[1;32m---> #{job.name}... done (#{job.num_completed}/#{job.num_workers})"
        when :failed   then "\033[1;31m---> #{job.name}... FAILED"
        when :killed   then "\033[1;33m---> #{job.name}... KILLED"
        end

        STDERR.puts "\033[2K#{status}\033[0m"
      end

      @last_num_printed_lines = jobs.size
      cleanup_jobs
    end
  end

  def cleanup_jobs
    loop do
      job = jobs.values.first
      if job && job.finished?
        jobs.delete(job.id)
        @last_num_printed_lines -= 1
      else
        break
      end
    end
  end

  class Multi
    attr_accessor :master, :jobs, :multi_signal

    def initialize(master)
      @master = master
      @jobs = []
      @multi_signal = Signal.new
    end

    def add_job(job)
      job.status_signals << @multi_signal
      @jobs << job
    end

    def wait
      failed_job = nil

      @multi_signal.wait_until do
        jobs.each { |job| failed_job = job if job.failed? }
        failed_job || jobs.all? { |job| job.finished? }
      end

      failed_job ? jobs.each(&:kill) : jobs.each(&:wait)
      master.redraw_progress
      check_for_failures
    end

    def check_for_failures
      jobs.each(&:check_for_failures)
    end

    def kill
      master.redis.pipelined { jobs.each(&:kill) }
    end

    def finalize
      jobs.each { |job| job.status_signals.delete(@multi_signal) }
    end
  end

  class Job
    attr_accessor :master, :options
    attr_accessor :output, :status, :status_signal, :status_signals
    attr_accessor :num_started, :num_completed

    def initialize(master, options={})
      @master = master
      @options = ::Thor::CoreExt::HashWithIndifferentAccess.new(options)
      @options[:id] ||= (0...10).map { (65 + rand(26)).chr }.join
      @status = :idle

      @num_started = 0
      @num_completed = 0

      @status_signal = Signal.new
      @status_signals = [@status_signal]
    end

    def id
      @options[:id]
    end

    def multi
      @options[:multi]
    end

    def name
      @options[:name] || "Job #{id}"
    end

    def tag
      (options[:tag] || '_all_').to_s.tap do |tag|
        raise "Cannot have multi tags" if tag.include?(',')
      end
    end

    def num_workers
      @options[:num_workers]
    end

    def job_payload
      @job_payload ||= begin
        script = if options[:file]
          File.read(options[:file])
        else
          cmd = options[:args].first
          cmd_args = options[:args][1..-1]
          "#{cmd} #{cmd_args.map { |a| "\"#{a}\"" }.join(" ")}"
        end

        unless script[0] == '#' && script[1] == '!'
          script = "#!/bin/bash\n" + script
        end

        { :type => 'script',
          :script => script,
          :id => self.id,
          :num_workers => self.num_workers }
      end
    end

    def on_progress_subscribe
      master.redis.pipelined do
        master.redis.set("abricot:job:#{id}:num_workers", 0)
        master.redis.expire("abricot:job:#{id}:num_workers", 600)
        master.redis.publish("abricot:slave_control:#{tag}", job_payload.to_json)
      end
    end

    def on_progress_message(msg)
      msg = JSON.parse(msg)
      case msg['type']
      when 'start' then
        @status = :started if @status == :idle
        @num_started += 1
        if @num_started == num_workers
          @status = :running if @status == :started
        end
      when 'done' then
        if @status != :failed
          if msg['status'] != 0
            master.redis_wait.unsubscribe("abricot:job:#{id}:progress")
            @output = msg['output']
            @status = :failed
            self._kill
            multi.kill if multi
          else
            @num_completed += 1
            if @num_completed == num_workers
              master.redis_wait.unsubscribe("abricot:job:#{id}:progress")
              @status = :success
            end
          end
        end
      end
      state_changed!
    end

    def check_for_enough_workers
      num_workers = options[:num_workers]
      available_workers = master.num_workers_available(tag)
      if num_workers
        if available_workers < num_workers
          @status = :failed
          raise NotEnoughSlaves.new("Requested #{num_workers} slaves but only #{available_workers} were available")
        end
      else
        if available_workers == 0
          @status = :failed
          raise NotEnoughSlaves.new("No workers available :(")
        end
        options[:num_workers] = available_workers
      end
    end

    def async_exec
      check_for_enough_workers
      master.redis_wait.client.call([:subscribe, "abricot:job:#{id}:progress"])
      self
    end

    def finished?
      @status == :success || @status == :failed || @status == :killed
    end

    def failed?
      @status == :failed
    end

    def state_changed!
      @status_signals.each(&:signal!)
    end

    def wait
      @status_signal.wait_until { finished? }
      master.redraw_mutex.synchronize {} # Finish redrawing
      check_for_failures
    end

    def check_for_failures
      raise JobFailure.new(@output) if @status == :failed
    end

    def _kill
      master.redis.publish('abricot:slave_control:_all_', {'type' => 'kill', 'id' => self.id.to_s}.to_json)
    end

    def kill
      return if finished?
      _kill
      master.redraw_mutex.synchronize do
        @status = :killed
        @output = 'Job killed'
      end
      master.redraw_progress
      state_changed!
    end
  end
end
