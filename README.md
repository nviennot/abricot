Abricot
=======

Fast cloud command dispatcher tool with Redis pub/sub.

Abricot was built to run benchmarks on a large amount of machines.

How to use
-----------

On each slave:

```
$ abricot listen
```

On the master:

```
$ abricot exec echo hello
```

### Specifying the redis server

Both the slaves and master accept the `--redis` argument (default is localhost).
Example:

```
$ abricot listen --redis redis://redis-server:port/db
```

### Tagging Slaves

You may tag slaves with multiple tags to allow master to pick which slaves get
to execute the job.

```
$ abricot listen --tags large,ruby
```

### Running a job on the command line

To run a job, you may pass several arguments:

* `-s CMD`: Run your command through bash
* `-f FILE`: Run a script file, which will be uploaded. You may use arbitrary
  scripts with `#!...` in the header.
* `-n NUM_WORKERS`: Run the job on exactly `NUM_WORKERS`.
* `-t TAG`: Run the job only on slaves tagged with `TAG`.

### Running a job programmatically

```ruby
require 'abricot/master'

@abricot = Abricot::Master.new(:redis => 'redis://master/1')

@abricot.exec <<-SCRIPT, :script => true, :name => "Saying Hello"
  touch /tmp/hello
  sleep 1
  echo "Hello"
SCRIPT
```

You may pass the following options:

* `:redis`: The Redis URL
* `:script`: true/false to tell if you are running a script.
* `:file`: A filename which file content will be uploaded and run as a script.
* `:num_workers`: How many workers to run the command/script on.
* `:tag`: a string to specify which tagged workers to run on.

### Killing any jobs

```ruby
@abricot.kill_all # kill all jobs running
@abricot.kill_all_jobs # kill all jobs that we started on @abricot
```

Note that a SIGINT (ctrl+c) will trigger a `kill_all_jobs`.

### Running a job programmatically (async)

```ruby
job1 = @abricot.async_exec %w(sleep 2)
job2 = @abricot.async_exec %w(sleep 1)

job1.wait
job2.kill
```

### Running jobs in batches

```ruby
@abricot.multi do
  @abricot.exec %w(sleep 2)
  @abricot.exec %w(sleep 1)
end
```

### Running jobs in batches (async)

```ruby
multi = @abricot.async_multi do
  @abricot.exec %w(sleep 2)
  @abricot.exec %w(sleep 1)
end

sleep 0.5
multi.kill
multi.wait
```

Note that the whole batch will be aborded if one of the command fails, and an
exception will be thrown in `wait()`.

License
--------

Abricot is released under LGPLv3
