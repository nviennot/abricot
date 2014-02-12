require 'abricot'
require 'tempfile'
require 'timeout'

class Abricot::Slave
  attr_accessor :redis, :redis_sub
  attr_accessor :runner_threads
  attr_accessor :tags

  def initialize(options={})
    @redis = Redis.new(:url => options[:redis])
    @redis_sub = Redis.new(:url => options[:redis])
    @runner_threads = {}
    @tags = options[:tags].to_s.split(',')
  end

  def listen
    trap(:INT) { puts; exit }

    channels = (@tags + ['_all_']).map { |t| "abricot:slave_control:#{t}" }
    begin
      connected = false
      redis_sub.subscribe(channels) do |on|
        on.subscribe do |channel, subscriptions|
          STDERR.puts "Connected. Listening for orders" unless connected
          connected = true
        end

        on.message do |channel, message|
          process_message(JSON.parse(message))
        end
      end
    rescue Redis::BaseConnectionError => e
      STDERR.puts "#{e}, retrying in 1s"
      sleep 1
      retry
    end
  end

  def process_message(msg)
    id = msg['id']
    if msg['tags']
      return if (@tags & msg['tags']).empty?
    end

    case msg['type']
    when 'killall' then kill_all_jobs
    when 'kill'    then kill_job(id)
    else
      worker_index = redis.incr("abricot:job:#{id}:num_workers") - 1
      num_workers = msg['num_workers']
      if worker_index < msg['num_workers']
        kill_job(id)
        @runner_threads[id] = Thread.new { run(worker_index, num_workers, msg) }
      end
    end
  end

  def kill_all_jobs
    runner_threads.keys.each { |k| kill_job(k) }
  end

  def kill_job(id)
    if thread = @runner_threads.delete(id.to_s)
      thread.join unless thread == Thread.current
    end
  end

  def run(worker_index, num_workers, options)
    id = options['id'].to_s

    STDERR.puts "-" * 80
    STDERR.puts "Running job: #{options}"
    STDERR.puts "-" * 80

    redis.publish("abricot:job:#{id}:progress", {'type' => 'start'}.to_json)

    output, status = case options['type']
    # 'exec' is no longer used. Keeping it if we need it later
    when 'exec' then exec_and_capture(id, worker_index, num_workers, *options['args'])
    when 'script' then
      file = Tempfile.new('abricot-')
      begin
        file.write(options['script'])
        file.chmod(0755)
        file.close
        exec_and_capture(id, worker_index, num_workers, file.path)
      ensure
        file.unlink
      end
    else raise "Unknown type"
    end

    return unless status

    # STDERR.puts output
    STDERR.puts "exited with #{status}"
    STDERR.puts "-" * 80
    STDERR.puts ""

    payload = {'type' => 'done'}
    payload['status'] = status
    payload['output'] = output if status != 0
    redis.publish("abricot:job:#{id}:progress", payload.to_json)

    kill_job(id)
  rescue Exception => e
    STDERR.puts e
    STDERR.puts e.backtrace.join("\n")
  end

  def exec_and_capture(job_id, worker_index, num_workers, *args)
    args = args.map(&:to_s)
    IO.popen('-') do |io|
      unless io
        ENV['WORKER_INDEX'] = worker_index.to_s
        ENV['NUM_WORKERS'] = num_workers.to_s

        Process.setpgrp

        $stderr.reopen($stdout)
        begin
          exec(*args)
        rescue Errno::ETXTBSY
          sleep 0.1
          retry
        rescue Exception => e
          STDERR.puts "#{e} while running #{args}"
          STDERR.puts e.backtrace.join("\n")
        end
        exit! 1
      end

      status = nil

      output = []
      loop do
        unless @runner_threads[job_id]
          STDERR.puts "Terminating Job (pid #{io.pid})"
          # - means process group
          Process.kill('-TERM', io.pid)
          break
        end

        rs, _, _ = IO.select([io], [], [], 0.1)
        if rs && rs.first
          begin
            buffer = io.readpartial(4096)
          rescue EOFError
            break
          end
          STDERR.print buffer
          output << buffer
        end
      end

      unless @runner_threads[job_id]
        begin
          Timeout.timeout(2) do
            _, status = Process.waitpid2(io.pid)
          end
        rescue Timeout::Error
          STDERR.puts "WARNING: Killing Job (pid #{io.pid})"
          Process.kill('-KILL', io.pid)
          _, status = Process.waitpid2(io.pid)
        end
          STDERR.puts "Job terminated. (pid #{io.pid})"
      else
        _, status = Process.waitpid2(io.pid)
      end

      [output.join, status.exitstatus]
    end
  end
end
