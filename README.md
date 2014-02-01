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

### Running a job

To run a job, you may pass several arguments:

* `-c CMD`: Run your command through bash
* `-f FILE`: Run a script file, which will be uploaded. You may use arbitrary
  scripts with `#!...` in the header.
* `-n NUM_WORKERS`: Run the job on exactly `NUM_WORKERS`.

License
--------

Abricot is released under LGPLv3
