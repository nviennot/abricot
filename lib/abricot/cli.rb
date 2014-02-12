require 'thor'

class Abricot::CLI < Thor
  desc "listen", "Start listening for orders"
  option :redis, :type => :string
  option :tags,  :type => :string, :aliases => :t
  def listen
    require 'abricot/slave'
    Abricot::Slave.new(options).listen
  end

  desc "exec ARGS...", "Run a command on slaves"
  option :redis,       :type => :string
  option :file,        :type => :string,  :aliases => :f
  option :num_workers, :type => :numeric, :aliases => :n
  option :id,          :type => :string
  option :tag,         :type => :string, :aliases => :t
  def exec(*args)
    require 'abricot/master'
    Abricot::Master.new(options).exec(*args, options)
  rescue Abricot::Master::NotEnoughSlaves => e
    STDERR.puts e.message
  rescue Abricot::Master::JobFailure => e
    STDERR.puts "JOB FAILURE:"
    STDERR.puts "-" * 80
    STDERR.puts e.message
  end
end
