require 'ruby-progressbar'

class Abricot::Master
  attr_accessor :redis, :redis_sub

  def initialize(options={})
    @redis = Redis.new(:url => options[:redis])
    @redis_sub = Redis.new(:url => options[:redis])
  end

  def num_workers_available
    redis.pubsub('numsub', 'abricot:slave_control').last.to_i
  end

  def exec(args, options={})
    options = options.dup
    options['id'] ||= (0...10).map { (65 + rand(26)).chr }.join

    trap(:INT) { puts; send_kill(options['id']) }
    _exec(args, options)
  end

  def _exec(args, options={})
    script = File.read(options['file']) if options['file']
    script ||= args.join(" ") if options['cmd']

    if script
      lines = script.lines.to_a
      unless lines.first =~ /^#!/
        lines = ['#!/bin/bash'] + lines
        script = lines.join("\n")
      end
      payload = {:type => 'script', :script => script}
    else
      payload = {:type => 'exec', :args => args}
    end

    id = options['id']
    payload[:id] = id

    num_workers = num_workers_available
    num_worker_start = 0
    num_worker_done = 0

    format = '%t |%b>%i| %c/%C'
    start_pb = ProgressBar.create(:format => format,  :title => 'start', :total => num_workers)
    done_pb = nil

    status = nil

    redis_sub.subscribe("abricot:job:#{id}:progress") do |on|
      on.subscribe do
        redis.publish('abricot:slave_control', payload.to_json)
      end

      on.message do |channel, message|
        msg = JSON.parse(message)
        case msg['type']
        when 'start' then
          num_worker_start += 1
          start_pb.progress = num_worker_start if start_pb
          if num_worker_start == num_workers
            start_pb.finish
            start_pb = nil
            done_pb = ProgressBar.create(:format => format, :title => 'done ', :total => num_workers)
          end
        when 'done' then
          if msg['status'] != 0
            start_pb = done_pb = nil
            STDERR.puts
            STDERR.puts "-" * 80
            STDERR.puts "JOB FAILURE"
            STDERR.puts "-" * 80
            STDERR.puts msg['output']
            STDERR.puts "-" * 80
            redis_sub.unsubscribe("abricot:job:#{id}:progress")
            status = :fail
          end

          num_worker_done += 1
          done_pb.progress = num_worker_done if done_pb
          if num_worker_done == num_workers
            done_pb.finish if done_pb
            redis_sub.unsubscribe("abricot:job:#{id}:progress")
            status = :success
          end
        end
      end
    end

    status
  end

  def send_kill(id)
    Thread.new { redis.publish('abricot:slave_control', {'type' => 'kill', 'id' => id.to_s}.to_json) }.join
    exit
  end

  def send_kill_all
    Thread.new { redis.publish('abricot:slave_control', {'type' => 'killall'}.to_json) }.join
    exit
  end
end
