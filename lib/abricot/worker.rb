require 'tempfile'

class Abricot::Worker
  attr_accessor :redis, :redis_sub
  attr_accessor :runner_thread


  def initialize(options={})
    @redis = Redis.new(:url => options[:redis])
    @redis_sub = Redis.new(:url => options[:redis])
  end

  def listen
    trap(:INT) { puts; exit }

    redis_sub.subscribe('abricot:job') do |on|
      on.message do |channel, message|
        msg = JSON.parse(message)
        if msg['type'] == 'kill'
          kill_current_job
        else
          kill_current_job
          @runner_thread = Thread.new { run(msg) }
        end
      end
    end
  end

  class Terminate < RuntimeError; end

  def kill_current_job
    if thread = @runner_thread
      @runner_thread = nil
      thread.join
    end
  end

  def run(options)
    STDERR.puts "-" * 80
    STDERR.puts "Running job: #{options}"
    STDERR.puts "-" * 80

    redis.publish('abricot:job:progress', {'type' => 'start'}.to_json)

    output = case options['type']
    when 'exec' then exec_and_capture(*options['args'])
    when 'script' then
      file = Tempfile.new('abricot-')
      begin
        file.write(options['script'])
        file.chmod(0755)
        file.close
        exec_and_capture(file.path)
      ensure
        file.delete
      end
    else raise "Unknown type"
    end

    STDERR.puts output
    STDERR.puts "-" * 80
    STDERR.puts ""

    redis.publish('abricot:job:progress', {'type' => 'done'}.to_json)

    @runner_thread = nil
  end

  def exec_and_capture(*args)
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
        if @runner_thread != Thread.current
          STDERR.puts "WARNING: Killing running job!"
          Process.kill('KILL', io.pid)
          return nil
        end

        if IO.select([io], [], [], 0.1)
          output += io.read
        end
      end
      output
    end
  end
end

# pubsub numsub <= num_worker
# command en cours -> non
