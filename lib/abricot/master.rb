require 'ruby-progressbar'

class Abricot::Master
  attr_accessor :redis, :redis_sub

  def initialize(options={})
    @redis = Redis.new(:url => options[:redis])
    @redis_sub = Redis.new(:url => options[:redis])
  end

  def num_workers_available
    redis.pubsub('numsub', 'abricot:job').last.to_i
  end

  def exec(args, options={})
    trap(:INT) { send_kill }
    _exec(args, options)
  end

  def _exec(args, options={})
    script = File.read(options[:file]) if options[:file]
    script ||= args.join(" ") if options[:cmd]

    if script
      lines = script.lines
      unless lines.first =~ /^#!/
        lines = ['#!/bin/bash'] + lines
        script = lines.join("\n")
      end
      payload = {:type => 'script', :script => script}
    else
      payload = {:type => 'exec', :args => args}
    end

    num_workers = num_workers_available
    num_worker_start = 0
    num_worker_done = 0

    start_pb = ProgressBar.create(:format => '%t |%b>%i| %c/%C %e',  :title => 'start', :total => num_workers)
    done_pb = nil

    redis_sub.subscribe('abricot:job:progress') do |on|
      on.subscribe do
        redis.publish('abricot:job', payload.to_json)
      end

      on.message do |channel, message|
        msg = JSON.parse(message)
        case msg['type']
        when 'start' then
          num_worker_start += 1
          start_pb.progress = num_worker_start
          if num_worker_start == num_workers
            start_pb.finish
            done_pb = ProgressBar.create(:format => '%t |%b>%i| %c/%C %e', :title => 'done', :total => num_workers)
          end
        when 'done' then
          num_worker_done += 1
          done_pb.progress = num_worker_done if done_pb
          if num_worker_done == num_workers
            done_pb.finish if done_pb
          end
        end
      end
    end
  end

  def send_kill
    Thread.new { redis.publish('abricot:job', {'type' => 'kill'}.to_json) }.join
    exit
  end
end
