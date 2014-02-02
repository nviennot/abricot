require 'ruby-progressbar'

class Abricot::Master
  class JobFailure < RuntimeError; end
  class NotEnoughSlaves < RuntimeError; end

  attr_accessor :redis

  def initialize(options={})
    @redis = Redis.new(:url => options[:redis])
  end

  def num_workers_available(tag)
    redis.pubsub('numsub', "abricot:slave_control:#{tag}").last.to_i
  end

  def exec(args, options={})
    options = options.dup
    options['id'] ||= (0...10).map { (65 + rand(26)).chr }.join

    trap(:INT) { puts; kill(options['id']) }
    _exec(args, options)
  end

  def _exec(args, options={})
    tag = options['tag'] || '_all_'
    raise "Cannot have multi tags" if tag.include?(',')

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

    num_workers = options['num_workers']
    available_workers = num_workers_available(tag)
    if num_workers
      if available_workers < num_workers
        raise NotEnoughSlaves.new("Requested #{num_workers} slaves but only #{available_workers} were available")
      end
    else
      num_workers = available_workers
    end

    id = options['id']
    payload[:id] = id
    payload[:num_workers] = num_workers

    num_worker_start = 0
    num_worker_done = 0

    format = '%t |%b>%i| %c/%C'
    unless options['quiet']
      start_pb = ProgressBar.create(:format => format,  :title => 'start', :total => num_workers,
                                    :throttle_rate => 0)
    end
    done_pb = nil
    status = nil
    output = nil

    redis_sub = Redis.new(:url => options[:redis])

    redis_sub.subscribe("abricot:job:#{id}:progress") do |on|
      on.subscribe do
        redis.set("abricot:job:#{id}:num_workers", 0)
        redis.expire("abricot:job:#{id}:num_workers", 600)

        redis.publish("abricot:slave_control:#{tag}", payload.to_json)
      end

      on.message do |channel, message|
        msg = JSON.parse(message)
        case msg['type']
        when 'start' then
          num_worker_start += 1
          start_pb.progress = num_worker_start
          if num_worker_start == num_workers
            start_pb.finish
            start_pb = nil
            unless options['quiet']
              done_pb = ProgressBar.create(:format => format, :title => 'done ', :throttle_rate => 0,
                                           :starting_at => num_worker_done, :total => num_workers)
            end
          end
        when 'done' then
          if status != :fail
            if msg['status'] != 0
              STDERR.puts
              start_pb = done_pb = nil
              redis_sub.unsubscribe("abricot:job:#{id}:progress")
              output = msg['output']
              status = :fail
            else
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
      end
    end

    redis_sub.quit rescue nil

    raise JobFailure.new(output) if status == :fail
  end

  def kill(id)
    Thread.new { redis.publish('abricot:slave_control:_all_', {'type' => 'kill', 'id' => id.to_s}.to_json) }.join
    exit
  end

  def kill_all
    Thread.new { redis.publish('abricot:slave_control:_all_', {'type' => 'killall'}.to_json) }.join
    exit
  end
end
