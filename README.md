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

```
$ abricot exec CMD [ARGS...]
```

To run a job, you may pass several arguments:

* `-f FILE`: Run a script file, which will be uploaded. You may use arbitrary
  scripts with `#!...` in the header. Arguments given on the command line are
  ignored.
* `-n NUM_WORKERS`: Run the job on exactly `NUM_WORKERS`.
* `-t TAG`: Run the job only on slaves tagged with `TAG`.

### Running a job programmatically

```ruby
require 'abricot/master'

@abricot = Abricot::Master.new(:redis => 'redis://localhost/1')

@abricot.exec <<-SCRIPT, :name => "Saying Hello"
  touch /tmp/hello
  sleep 1
  echo "Hello"
SCRIPT

@abricot.exec <<-SCRIPT, :name => "Saying Hello"
#!/usr/bin/env ruby
puts "Hello"
SCRIPT

@abricot.exec "echo", "Hello"
```

You may pass the following options to `exec()`:

* `:num_workers`: How many workers to run the command/script on.
* `:tag`: a string to specify which tagged workers to run on.
* `:async`: run the job asynchronously.

### Killing any jobs

```ruby
@abricot.kill_all # kill all jobs running
@abricot.kill_all_jobs # kill all jobs that we started on @abricot
```

Note that a SIGINT (ctrl+c) will trigger a `kill_all_jobs`.
Killing jobs is done by issuing a SIGTERM, and then 2 seconds later, a SIGKILL if
the process did not respond to the SIGTERM.

### Running a job programmatically (async)

```ruby
job1 = @abricot.exec "sleep 2", :async => true
job2 = @abricot.exec "sleep 1", :async => true

job1.wait
job2.kill
```

### Running jobs in batches

```ruby
@abricot.multi do
  @abricot.exec "sleep 2"
  @abricot.exec "sleep 1"
end
```

### Running jobs in batches (async)

```ruby
multi = @abricot.multi :async => true do
  @abricot.exec "sleep 2"
  @abricot.exec "sleep 1"
end

multi.check_for_failures # returns immediately, raises if any job had a failure
multi.kill # kill all jobs
multi.wait # wait for all jobs
```

Note that the whole batch will be aborded if one of the command fails, and an
exception will be thrown in `wait()`.

### Exceptions

You may get the following exceptions when running jobs:
`Abricot::Master::JobFailure`
`Abricot::Master::NotEnoughSlaves`.

License
--------

Abricot is released under LGPLv3
