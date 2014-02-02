require 'tempfile'

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
      if redis.incr("abricot:job:#{id}:num_workers") <= msg['num_workers']
        kill_job(id)
        @runner_threads[id] = Thread.new { run(msg) }
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

  def run(options)
    id = options['id'].to_s

    STDERR.puts "-" * 80
    STDERR.puts "Running job: #{options}"
    STDERR.puts "-" * 80

    redis.publish("abricot:job:#{id}:progress", {'type' => 'start'}.to_json)

    output, status = case options['type']
    when 'exec' then exec_and_capture(id, *options['args'])
    when 'script' then
      file = Tempfile.new('abricot-')
      begin
        file.write(options['script'])
        file.chmod(0755)
        file.close
        exec_and_capture(id, file.path)
      ensure
        file.delete
      end
    else raise "Unknown type"
    end

    return unless status

    STDERR.puts output
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
  end

  def exec_and_capture(job_id, *args)
    args = args.map(&:to_s)
    IO.popen('-') do |io|
      unless io
        trap("SIGINT", "IGNORE")
        trap("SIGTERM", "IGNORE")
        $stderr.reopen($stdout)
        begin
          exec(*args)
        rescue Exception => e
          STDERR.puts "#{e} while running #{args}"
        end
        exit! 1
      end

      status = nil

      output = []
      loop do
        unless @runner_threads[job_id]
          STDERR.puts "WARNING: Killing Running Job!"
          Process.kill('KILL', io.pid)
          break
        end

        if IO.select([io], [], [], 0.1)
          buffer = io.read
          break if buffer.empty?
          output << buffer
        end
      end

      _, status = Process.waitpid2(io.pid)
      [output.join, status.exitstatus]
    end
  end
end

# pubsub numsub <= num_worker
# command en cours -> non
