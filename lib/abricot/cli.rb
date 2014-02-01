require 'thor'

class Abricot::CLI < Thor
  desc "worker", "Start listening for orders"
  option :redis
  def listen
    require 'abricot/worker'
    Abricot::Worker.new(options).listen
  end

  desc "exec ARGS...", "Run a command on slaves"
  option :redis,       :type => :string
  option :cmd,         :type => :boolean, :aliases => :c
  option :file,        :type => :string,  :aliases => :f
  option :num_workers, :type => :numeric, :aliases => :n
  option :id,          :type => :string
  def exec(*args)
    require 'abricot/master'
    Abricot::Master.new(options).exec(args, options)
  end
end
