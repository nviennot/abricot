require 'tempfile'

class Abricot::Worker
  attr_accessor :redis, :redis_sub
  attr_accessor :runner_threads


  def initialize(options={})
    @redis = Redis.new(:url => options[:redis])
    @redis_sub = Redis.new(:url => options[:redis])
    @runner_threads = {}
  end

  def listen
    trap(:INT) { puts; exit }

    redis_sub.subscribe('abricot:slave_control') do |on|
      on.message do |channel, message|
        msg = JSON.parse(message)
        id = msg['id']
        case msg['type']
        when 'killall' then kill_all_jobs
        when 'kill'    then kill_job(id)
        else
          kill_job(id)
          @runner_threads[id] = Thread.new { run(msg) }
        end
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

    output = case options['type']
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

    STDERR.puts output
    STDERR.puts "-" * 80
    STDERR.puts ""

    redis.publish("abricot:job:#{id}:progress", {'type' => 'done'}.to_json)

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

      output = []
      loop do
        unless @runner_threads[job_id]
          STDERR.puts "WARNING: Killing running job!"
          Process.kill('KILL', io.pid)
          return nil
        end

        if IO.select([io], [], [], 0.1)
          buffer = io.read
          break if buffer.empty?
          output << buffer
        end
      end
      output.join
    end
  end
end

# pubsub numsub <= num_worker
# command en cours -> non
