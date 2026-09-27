# Solid Redis

[![Build Status](https://github.com/nicolasva/solid-redis/actions/workflows/ci.yml/badge.svg)](https://github.com/nicolasva/solid-redis/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/solid-redis.svg)](https://rubygems.org/gems/solid-redis)
[![Downloads](https://img.shields.io/gem/dt/solid-redis?style=flat)](https://rubygems.org/gems/solid-redis)
[![Documentation Status](https://img.shields.io/badge/docs-RubyDoc.info-blue.svg)](https://www.rubydoc.info/gems/solid-redis)

`solid-redis` is a dependency-free Redis client designed around Ractor
isolation. Its Redis, Sentinel, and Cluster specifications are immutable and
shareable; every Ractor creates and retains its own resolution state, slot
table, mutex, pool, clients, and sockets.

It supports standalone Redis, Sentinel failover, Redis Cluster routing,
pipelines, blocking commands, and Pub/Sub. It does not depend on or patch
`redis-client`.

The implementation intentionally composes two small gems from the same
author:

- [`base-service`](https://github.com/nicolasva/base-service) executes each
  Sentinel resolution and Cluster topology discovery and returns its immutable
  result and endpoint errors;
- [`callback-collection`](https://github.com/nicolasva/callback-collection)
  provides immutable lifecycle event handlers.

## Architecture

```text
                       RUBY
                         |
             immutable/shareable config
                         |
        +----------------+----------------+
        |                |                |
     Ractor A         Ractor B         Ractor C
        |                |                |
  SentinelState A  SentinelState B  SentinelState C
        |                |                |
     Mutex A          Mutex B          Mutex C
        |                |                |
      Pool A           Pool B           Pool C
        |                |                |
     Socket A         Socket B         Socket C
        |                |                |
        +----------------+----------------+
                         |
                   Redis/Sentinel
```

`SolidRedis::SentinelConfig` contains only declarative values. It can therefore
cross a Ractor boundary. Its first use in each Ractor creates a
`SolidRedis::SentinelState` in `Ractor.current` storage. The state owns:

- the cached Redis target;
- the current Sentinel ordering;
- dynamically discovered Sentinels;
- temporary Sentinel clients;
- a mutex protecting threads in that Ractor.

Sentinel connections are opened only while resolving a target and are then
closed. Resolution is cached until `reset` or a connection/failover error.

`SolidRedis::ClusterConfig` follows the same pattern: the shareable
specification holds the seed nodes, and each Ractor keeps a
`SolidRedis::ClusterState` with its slot table, one client per node, and its
own mutex. `MOVED` replies update only the local table. Pub/Sub subscriptions
and blocking commands likewise run on connections owned by the calling Ractor.

## Requirements

Ruby **3.1 or newer** is required (tested on 3.1, 3.2, 3.3, 3.4, and 4.0).
Ruby 2.7 and 3.0 are not supported: the `Ractor` API this gem is built on
was introduced in 3.0, and the per-Ractor storage semantics are verified
from 3.1 onwards. Ruby >= 4.0 is recommended for workloads that run several
threads inside several Ractors (see the CRuby limitation below).

## Installation

```ruby
gem "solid-redis"
```

```sh
bundle install
```

## Direct Redis usage

```ruby
require "solid_redis"

config = SolidRedis.config(
  url: "redis://localhost:6379/0",
  timeout: 1.0,
  reconnect_attempts: 1
)

client = config.new_client
client.call("SET", "answer", 42)
client.call("GET", "answer") # => "42"
client.close
```

The client supports TCP, Unix sockets, TLS, RESP2 and RESP3 response types,
AUTH, SELECT, CLIENT SETNAME, calls, vector calls, and pipelines:

```ruby
client.pipelined do |pipeline|
  pipeline.call("SET", "first", 1)
  pipeline.call("GET", "first")
end
# => ["OK", "1"]
```

## Sentinel with Ractors

Create one immutable specification and pass it to every worker:

```ruby
SENTINEL = SolidRedis.sentinel(
  name: "mymaster",
  sentinels: [
    { host: "127.0.0.1", port: 26_380 },
    { host: "127.0.0.1", port: 26_381 }
  ],
  role: :master,
  timeout: 1.0
)

Ractor.shareable?(SENTINEL) # => true

workers = 4.times.map do
  Ractor.new(SENTINEL) do |sentinel|
    pool = sentinel.new_pool(size: 5)
    pool.call("PING")
  ensure
    pool&.close
  end
end

workers.map(&:value) # => ["PONG", "PONG", "PONG", "PONG"]
# On Ruby 3.x, use workers.map(&:take) instead.
```

Each Ractor resolves `mymaster` independently on first use. A connection error
invalidates only that Ractor's cached target and causes its next connection
attempt to query Sentinel again.

For replicas, pass `role: :replica` (the `:slave` alias is accepted).
Unavailable replicas marked `s_down`, `o_down`, or `disconnected` are ignored.

Sentinel credentials and TLS are independent from Redis credentials and TLS:

```ruby
SolidRedis.sentinel(
  name: "mymaster",
  sentinels: ["rediss://sentinel-user:secret@sentinel.example:26379"],
  username: "redis-user",
  password: "redis-secret",
  ssl: true,
  ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_PEER },
  sentinel_ssl: true,
  sentinel_ssl_params: { verify_mode: OpenSSL::SSL::VERIFY_PEER }
)
```

## Per-Ractor pool

`new_pool` creates a conventional thread-safe pool owned by the calling
Ractor:

```ruby
pool = SENTINEL.new_pool(size: 5, timeout: 1.0)

pool.with do |client|
  client.call("INCR", "jobs")
end

pool.call("GET", "jobs")
pool.close
```

The pool may be shared by threads in its owning Ractor. It must not be sent to
another Ractor. Create a separate pool inside every Ractor, as in the example
above.

## Blocking commands

`blocking_call(timeout, *command)` runs BLPOP, BRPOP, BZPOPMIN, XREAD BLOCK
and similar commands. The socket read timeout becomes `timeout` plus the
configured `read_timeout`; pass `nil` or `0` when Redis blocks indefinitely.

```ruby
pool.blocking_call(5, "BLPOP", "jobs", 5)   # => ["jobs", "payload"] or nil
pool.blocking_call(nil, "BLPOP", "jobs", 0) # waits forever
```

A blocking command is never retried after a connection error, because the
element may already have been consumed. While it waits, its connection stays
checked out: size pools with room for concurrent blocking waiters plus regular
traffic, and keep the pool `timeout` short so other threads fail fast instead
of freezing.

## Pub/Sub

`new_subscription` opens a dedicated connection that belongs to the calling
Ractor and is never taken from a pool.

```ruby
subscription = config.new_subscription
subscription.subscribe("events").psubscribe("alerts.*")

subscription.each_message(timeout: 1.0) do |message|
  next if message.nil?          # timeout elapsed: check a stop flag here
  next unless message.message?  # skip subscribe/unsubscribe/pong events

  puts "#{message.channel}: #{message.payload}"
end
```

`Message` is a frozen struct with `type` (`:message`, `:pmessage`,
`:smessage`, `:subscribe`, `:psubscribe`, `:ssubscribe`, `:unsubscribe`,
`:punsubscribe`, `:sunsubscribe`, `:pong`), `channel`, `pattern`, and
`payload`. `next_message(timeout:)` returns one message or `nil`; `ping`
sends a keepalive answered by a `:pong` message. Sharded channels use
`ssubscribe`/`sunsubscribe`.

After a connection loss the subscription reconnects according to
`reconnect_attempts` and re-issues its tracked channels and patterns; the
confirmations flow back as `:subscribe`/`:psubscribe` messages. Regular
commands raise `SolidRedis::Error` on a subscription.

The natural Ractor pattern is one listener Ractor fanning out plain Strings to
workers:

```ruby
port = Ractor::Port.new # Ruby >= 4.0; use Ractor.yield/take on 3.x

listener = Ractor.new(CONFIG, port) do |config, port|
  subscription = config.new_subscription
  subscription.subscribe("events")
  subscription.each_message do |message|
    port << [message.channel, message.payload].freeze if message&.message?
  end
end

loop do
  channel, payload = port.receive
  # dispatch to application Ractors
end
```

## Redis Cluster

`SolidRedis.cluster` builds an immutable, shareable specification from seed
nodes. Each Ractor discovers the slot table with `CLUSTER SLOTS` on first use
and keeps it, together with one connection per node, in Ractor-local state.

```ruby
CLUSTER = SolidRedis.cluster(
  nodes: ["redis://10.0.0.1:7000", "10.0.0.2:7000"],
  password: ENV["REDIS_PASSWORD"],
  timeout: 1.0,
  max_redirections: 5
)

Ractor.shareable?(CLUSTER) # => true

client = CLUSTER.new_client
client.call("SET", "user:1", "Ada")
client.call("GET", "user:1")
client.call("MGET", "{user:1}.name", "{user:1}.email") # same slot via hash tag

client.pipelined do |pipeline|
  pipeline.call("GET", "a")   # commands are grouped into one pipeline
  pipeline.call("GET", "b")   # per node, and results come back
  pipeline.call("PING")       # in their original order
end

pool = CLUSTER.new_pool(size: 5) # a pool of cluster clients
```

Routing uses CRC16 hash slots with `{hash tag}` support and knows the key
position of EVAL/FCALL, XREAD/XREADGROUP, ZUNION-style and keyless commands.
`MOVED` updates the local slot table; `ASK` is followed once with `ASKING`;
`TRYAGAIN`/`CLUSTERDOWN` trigger a topology refresh. `CROSSSLOT` errors from
Redis are raised as `SolidRedis::CommandError`. Cluster only supports database
`0`; `blocking_call` is routed like any other command.

## Configuration

Direct Redis options:

| Option | Default | Description |
|---|---:|---|
| `url` | | `redis://`, `rediss://`, or `unix://` URL |
| `host` | `127.0.0.1` | Redis host |
| `port` | `6379` | Redis port |
| `path` | | Unix socket path |
| `username` | | ACL username |
| `password` | | Password |
| `db` | `0` | Database number |
| `timeout` | `1.0` | Default connect/read/write timeout |
| `connect_timeout` | `timeout` | Connection timeout |
| `read_timeout` | `timeout` | Read timeout |
| `write_timeout` | `timeout` | Write timeout |
| `reconnect_attempts` | `1` | Retries after a connection error |
| `ssl` | `false` | Enable TLS |
| `ssl_params` | | Immutable `OpenSSL::SSL::SSLContext` attributes |

An explicit `db:` option takes precedence over a database selected by the URL
path or `?db=` query parameter. When neither specifies a database, it defaults
to `0`.

Sentinel additionally requires `name` and `sentinels`, and accepts `role`,
`sentinel_username`, `sentinel_password`, `sentinel_ssl`, and
`sentinel_ssl_params`. Sentinel defaults to two reconnect attempts.

Cluster requires `nodes` (host:port strings, `redis://` URLs, or hashes) and
accepts `max_redirections` (default `5`) plus the direct Redis options above
except `db`, which must be `0`.

All configuration is copied and deeply frozen. Proc credentials and mutable
objects such as `OpenSSL::X509::Store` are rejected because Ruby cannot make
them Ractor-shareable. Prefer immutable values and paths in TLS parameters.

## Lifecycle callbacks

Pass a shareable `CallbackCollection` through `callbacks:` to observe
`connected`, `disconnected`, `connection_error`, and `resolved` events:

```ruby
module RedisEvents
  def self.connected(url)
    Logger.info("Connected to #{url}")
  end

  def self.connection_error(type, message)
    Logger.warn("#{type}: #{message}")
  end
end

callbacks = CallbackCollection.new do |collection|
  collection.register(:connected, RedisEvents)
  collection.register(:connection_error, RedisEvents)
end

config = SolidRedis.sentinel(
  name: "mymaster",
  sentinels: [{ host: "127.0.0.1", port: 26_379 }],
  callbacks: callbacks
)
```

| Callback | Arguments |
|---|---|
| `connected` | resolved server URL |
| `disconnected` | resolved server URL |
| `connection_error` | exception class name and message |
| `resolved` | Sentinel name and resolved server URL, or `"cluster"` and the node list |

Method registration is required for a Ractor-shareable callback collection.
Block callbacks retain mutable lexical context and are therefore rejected.
Callback exceptions propagate to the caller.

## Examples

### Parallel job workers, one Ractor each

Every worker receives the same shareable Sentinel specification and builds
its own pool. Nothing but the specification and plain data crosses the
Ractor boundary.

```ruby
SENTINEL = SolidRedis.sentinel(
  name: "mymaster",
  sentinels: ["redis://sentinel-1:26379", "redis://sentinel-2:26379"],
  password: ENV.fetch("REDIS_PASSWORD"),
  timeout: 1.0
)

workers = 4.times.map do |index|
  Ractor.new(SENTINEL, index) do |sentinel, worker_id|
    pool = sentinel.new_pool(size: 2)
    processed = 0

    while (job = pool.call("RPOP", "jobs"))
      pool.call("HINCRBY", "stats", "worker:#{worker_id}", 1)
      processed += 1
    end

    processed
  ensure
    pool&.close
  end
end

workers.sum(&:value) # total processed jobs (use &:take on Ruby 3.x)
```

### Threads sharing a pool inside one Ractor

Threads within a Ractor may share a pool. On CRuby < 4.0 keep all threads in
a single Ractor (see the limitation below).

```ruby
pool = SolidRedis.config(url: "redis://localhost:6379").new_pool(size: 8)

threads = 20.times.map do |i|
  Thread.new { pool.call("SET", "key:#{i}", i) }
end
threads.each(&:join)

pool.call("DBSIZE") # => 20
pool.close
```

### Pipelines and error handling

`call` raises `SolidRedis::CommandError` on a Redis error reply. A pipeline
sends all commands in one round trip and reads every reply. By default it
then raises the first `CommandError` if any; pass `exception: false` to get
errors back in place and keep the other results.

```ruby
client = SolidRedis.config(url: "redis://localhost:6379").new_client

begin
  client.call("INCR", "not-a-number")
rescue SolidRedis::CommandError => error
  error.message # => "ERR value is not an integer or out of range"
end

client.pipelined do |pipeline|
  pipeline.call("SET", "counter", 1)
  pipeline.call("INCR", "counter")
  pipeline.call("GET", "counter")
end
# => ["OK", 2, "2"]

begin
  client.pipelined do |pipeline|
    pipeline.call("SET", "counter", "abc")
    pipeline.call("INCR", "counter") # fails; the SET was still applied
  end
rescue SolidRedis::CommandError => error
  error.message # => "ERR value is not an integer or out of range"
end

results = client.pipelined(exception: false) do |pipeline|
  pipeline.call("SET", "counter", "abc")
  pipeline.call("INCR", "counter")
  pipeline.call("GET", "counter")
end
# => ["OK", #<SolidRedis::CommandError: ERR value is not an integer...>, "abc"]

results.each { |result| raise result if result.is_a?(SolidRedis::CommandError) }
```

### Building commands dynamically

`call_v` accepts an array, which is convenient for variadic commands.

```ruby
fields = { "name" => "Ada", "language" => "Ruby" }
client.call_v(["HSET", "user:1", *fields.flatten])
client.call("HGETALL", "user:1")
# => { "name" => "Ada", "language" => "Ruby" } with RESP3
# => ["name", "Ada", "language", "Ruby"]     with RESP2
```

### Reading from replicas

Use `role: :replica` for read-only traffic and keep a separate `:master`
specification for writes. Both are shareable and resolve independently.

```ruby
WRITER = SolidRedis.sentinel(name: "mymaster", sentinels: SENTINELS, role: :master)
READER = SolidRedis.sentinel(name: "mymaster", sentinels: SENTINELS, role: :replica)

Ractor.new(WRITER, READER) do |writer, reader|
  writer.new_client.call("SET", "greeting", "hello")
  reader.new_client.call("GET", "greeting") # after replication
end
```

### Observing failover

After a connection error the Ractor's cached target is dropped and the next
attempt asks Sentinel again. Register a callback to trace it.

```ruby
module FailoverLog
  def self.connection_error(type, message) = warn("[redis] #{type}: #{message}")
  def self.resolved(name, url)             = warn("[redis] #{name} -> #{url}")
end

callbacks = CallbackCollection.new do |collection|
  collection.register(:connection_error, FailoverLog)
  collection.register(:resolved, FailoverLog)
end

sentinel = SolidRedis.sentinel(
  name: "mymaster",
  sentinels: SENTINELS,
  reconnect_attempts: 2,
  callbacks: callbacks
)

client = sentinel.new_client
client.call("PING")            # [redis] mymaster -> redis://10.0.0.15:6379
# ... master goes down, Sentinel promotes a replica ...
client.call("PING")            # [redis] ConnectionError: Connection reset by peer
                               # [redis] mymaster -> redis://10.0.0.16:6379
```

### Strict at-most-once delivery

Retries after a connection error may replay a command. Disable them for
non-idempotent operations and handle the error yourself.

```ruby
config = SolidRedis.config(url: "redis://localhost:6379", reconnect_attempts: 0)
client = config.new_client

begin
  client.call("LPUSH", "payments", payment_id)
rescue SolidRedis::ConnectionError
  # Nothing was retried; decide whether to re-enqueue.
end
```

### Unix socket and TLS

```ruby
SolidRedis.config(url: "unix:///var/run/redis/redis.sock", db: 2)

SolidRedis.config(
  url: "rediss://redis.example:6380",
  ssl_params: {
    verify_mode: OpenSSL::SSL::VERIFY_PEER,
    ca_file: "/etc/ssl/certs/redis-ca.pem"
  }
)
```

## Semantics and current scope

- Clients, pools, sockets, mutexes, Sentinel runtime state, and Cluster slot
  tables are never shared between Ractors.
- Multiple threads in one Ractor share one protected Sentinel resolution or
  Cluster topology.
- Redis command errors are never retried.
- Connection errors may retry a command according to `reconnect_attempts`.
  Applications requiring strict at-most-once semantics should set it to `0`.
  Blocking commands and Pub/Sub never replay a command.
- A pool waits up to its checkout timeout and then raises
  `SolidRedis::CheckoutTimeoutError`.
- Cluster clients follow up to `max_redirections` MOVED/ASK redirections and
  refresh the topology on TRYAGAIN/CLUSTERDOWN, then raise
  `SolidRedis::FailoverError`.
- Transactions helpers (MULTI/EXEC/WATCH), Cluster replica reads, middleware,
  and an asynchronous actor pool are not part of version `1.0`.

### Known CRuby limitation

Ractor support in CRuby is still experimental. On CRuby 3.4, running
**multiple threads inside multiple Ractors simultaneously** can hang
intermittently in the VM scheduler. This is reproducible with plain
`Thread` + CPU work in bare Ractors, without solid-redis, and is fixed
by the Ractor rewrite in CRuby >= 4.0 (verified by
`test/ractor_stress_test.rb`, which is skipped on older Rubies).
Safe patterns on CRuby 3.x:

- one thread per Ractor (the natural Ractor model), or
- multiple threads and a pool inside a single Ractor.

Both are fully supported by this gem.

An asynchronous `new_ractor_pool` would be a separate API: worker Ractors
would own connections and exchange commands/results through messages or
futures. It cannot transparently replace a block-based synchronous pool
without defining backpressure, cancellation, transaction, Pub/Sub, and
exception protocols.

## Benchmark

<!-- benchmark-results:start -->
This is a local-loopback microbenchmark, not a prediction of application
performance. It excludes Redis server CPU/RAM and network latency.
Cluster rows compare `solid-redis` with `redis-cluster-client`, the
Cluster implementation built on `redis-client`. Unsupported combinations
are reported rather than replaced with a different concurrency model.

**Environment:** Ruby 3.4.4 (arm64-darwin24); solid-redis 1.0.3; Redis server v=8.10.0 sha=00000000:1 malloc=libc bits=64 build=80fd3081013fc32b; redis-client 0.30.1; redis-cluster-client 0.17.1; Apple M2 Max, 12 logical CPUs, 96 GiB RAM, macOS 26.6.2.

Each row is measured in a fresh Ruby process. Both clients use RESP2,
identical commands and the same local Redis topology. Client order is
alternated between runs; values are medians of 5 runs.
Regular workloads warm for 2 seconds and measure
for 10 seconds. Pipeline latency is amortized
per command (batch size 50). The isolated-pool scenario creates a
five-connection pool inside each Ractor, warms it with
1,000 PINGs, then measures 100,000
PINGs per Ractor.
CPU is client-process CPU divided by wall time and may exceed 100% with
multiple Ractors. Peak RSS excludes Redis server processes. Sentinel
rows kill the master process 0.5 seconds after measurement starts and
verify that every Ractor resumes on the promoted replica. Recovery is
measured from the kill to each Ractor's first successful response.
Throughput counts successful commands; errors are failed commands
observed during the measured interval. Allocation and RSS measurements
include the identical latency-recording harness used for both clients, so
they are comparative rather than intrinsic library-only costs.

Reproduce the full run (requires `redis-server` and `redis-cli`):

```sh
BENCHMARK_README=README.md bundle exec rake benchmark:comparison
```

### GET / SET

| Ractors | Client | Throughput (ops/s) | p50 (ms) | p95 (ms) | p99 (ms) | CPU | Peak RSS | Allocations/op | Errors/run |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | `redis-client` | 35,636 | 0.027 | 0.033 | 0.045 | 58.3% | 50.6 MiB | 17.4 | 0 |
| 1 | `solid-redis` | 33,891 | 0.028 | 0.034 | 0.051 | 52.4% | 49.0 MiB | 28.9 | 0 |
| 2 | `redis-client` | 53,941 | 0.035 | 0.049 | 0.069 | 114.6% | 58.6 MiB | 17.3 | 0 |
| 2 | `solid-redis` | 56,594 | 0.033 | 0.045 | 0.090 | 104.7% | 57.9 MiB | 28.7 | 0 |
| 4 | `redis-client` | 67,608 | 0.055 | 0.092 | 0.131 | 238.3% | 63.7 MiB | 17.3 | 0 |
| 4 | `solid-redis` | 75,539 | 0.049 | 0.082 | 0.141 | 204.1% | 63.8 MiB | 28.5 | 0 |
| 8 | `redis-client` | 48,828 | 0.078 | 0.171 | 0.236 | 268.5% | 75.4 MiB | 17.3 | 0 |
| 8 | `solid-redis` | 80,691 | 0.087 | 0.172 | 0.267 | 431.4% | 69.5 MiB | 28.2 | 0 |

### Pipelines

| Ractors | Client | Throughput (ops/s) | p50 (ms) | p95 (ms) | p99 (ms) | CPU | Peak RSS | Allocations/op | Errors/run |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | `redis-client` | 262,482 | 0.004 | 0.005 | 0.007 | 81.5% | 39.5 MiB | 12.6 | 0 |
| 1 | `solid-redis` | 317,150 | 0.003 | 0.004 | 0.006 | 77.9% | 41.0 MiB | 16.2 | 0 |
| 2 | `redis-client` | 270,197 | 0.007 | 0.010 | 0.013 | 149.9% | 39.9 MiB | 12.5 | 0 |
| 2 | `solid-redis` | 459,445 | 0.004 | 0.007 | 0.009 | 147.5% | 42.5 MiB | 15.9 | 0 |
| 4 | `redis-client` | 222,813 | 0.017 | 0.025 | 0.031 | 282.8% | 40.0 MiB | 12.5 | 0 |
| 4 | `solid-redis` | 464,640 | 0.008 | 0.014 | 0.017 | 251.9% | 43.2 MiB | 15.6 | 0 |
| 8 | `redis-client` | 204,898 | 0.004 | 0.055 | 0.063 | 314.2% | 41.9 MiB | 12.5 | 0 |
| 8 | `solid-redis` | 341,323 | 0.021 | 0.042 | 0.047 | 550.7% | 43.4 MiB | 15.5 | 0 |

### Isolated pool per Ractor

| Ractors | Client | Throughput (ops/s) | p50 (ms) | p95 (ms) | p99 (ms) | CPU | Peak RSS | Allocations/op | Errors/run |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | `redis-client` | unsupported: Ractor::IsolationError (`connection_pool` uses non-shareable global state) | — | — | — | — | — | — | — |
| 1 | `solid-redis` | 34,528 | 0.028 | 0.033 | 0.043 | 53.3% | 39.0 MiB | 25.0 | 0 |
| 2 | `redis-client` | unsupported: Ractor::IsolationError (`connection_pool` uses non-shareable global state) | — | — | — | — | — | — | — |
| 2 | `solid-redis` | 57,408 | 0.032 | 0.046 | 0.086 | 106.3% | 44.4 MiB | 24.8 | 0 |
| 4 | `redis-client` | unsupported: Ractor::IsolationError (`connection_pool` uses non-shareable global state) | — | — | — | — | — | — | — |
| 4 | `solid-redis` | 78,461 | 0.047 | 0.078 | 0.129 | 205.4% | 54.1 MiB | 24.6 | 0 |
| 8 | `redis-client` | unsupported: Ractor::IsolationError (`connection_pool` uses non-shareable global state) | — | — | — | — | — | — | — |
| 8 | `solid-redis` | 72,809 | 0.071 | 0.129 | 0.202 | 297.3% | 68.9 MiB | 24.4 | 0 |

### Cluster

| Ractors | Client | Throughput (ops/s) | p50 (ms) | p95 (ms) | p99 (ms) | CPU | Peak RSS | Allocations/op | Errors/run |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | `redis-client` | 29,071 | 0.033 | 0.040 | 0.051 | 64.8% | 48.8 MiB | 19.4 | 0 |
| 1 | `solid-redis` | 29,213 | 0.033 | 0.038 | 0.056 | 57.1% | 47.6 MiB | 34.9 | 0 |
| 2 | `redis-client` | 50,333 | 0.037 | 0.051 | 0.078 | 124.7% | 57.8 MiB | 19.3 | 0 |
| 2 | `solid-redis` | 51,805 | 0.036 | 0.050 | 0.097 | 117.2% | 57.0 MiB | 34.7 | 0 |
| 4 | `redis-client` | 60,752 | 0.062 | 0.099 | 0.139 | 252.6% | 62.5 MiB | 19.3 | 0 |
| 4 | `solid-redis` | 66,626 | 0.055 | 0.089 | 0.152 | 225.9% | 61.2 MiB | 34.4 | 0 |
| 8 | `redis-client` | 43,258 | 0.089 | 0.186 | 0.253 | 278.1% | 75.4 MiB | 19.3 | 0 |
| 8 | `solid-redis` | 48,644 | 0.079 | 0.154 | 0.248 | 241.4% | 74.7 MiB | 34.3 | 0 |

### Sentinel master crash

| Ractors | Client | Throughput (ops/s) | p50 (ms) | p95 (ms) | p99 (ms) | Recovery p50 (ms) | Recovery max (ms) | CPU | Peak RSS | Allocations/op | Errors/run |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | `redis-client` | 29,378 | 0.028 | 0.035 | 0.046 | 1333.8 | 1333.8 | 61.9% | 52.3 MiB | 20.1 | 2050 |
| 1 | `solid-redis` | 28,794 | 0.029 | 0.035 | 0.050 | 1319.1 | 1319.1 | 55.5% | 48.3 MiB | 33.3 | 2090 |
| 2 | `redis-client` | 30,829 | 0.036 | 0.049 | 0.070 | 4242.9 | 4243.0 | 87.8% | 53.4 MiB | 20.4 | 3080 |
| 2 | `solid-redis` | 31,074 | 0.033 | 0.045 | 0.093 | 4440.4 | 4451.4 | 77.3% | 50.3 MiB | 33.1 | 2202 |
| 4 | `redis-client` | 36,404 | 0.054 | 0.093 | 0.131 | 4302.8 | 4870.8 | 157.2% | 58.0 MiB | 20.5 | 3113 |
| 4 | `solid-redis` | 41,080 | 0.048 | 0.081 | 0.136 | 4802.3 | 4962.6 | 132.6% | 56.0 MiB | 32.0 | 2251 |
| 8 | `redis-client` | 48,133 | 0.117 | 0.219 | 0.297 | 2278.4 | 2741.5 | 434.1% | 61.5 MiB | 19.7 | 3114 |
| 8 | `solid-redis` | 63,627 | 0.087 | 0.171 | 0.277 | 2073.7 | 2085.0 | 374.0% | 64.4 MiB | 30.6 | 2268 |
<!-- benchmark-results:end -->

## Development

```sh
bundle install
bundle exec rake
```

The default task runs the Minitest suite, a deterministic local throughput
benchmark, and builds the gem in `pkg/`. CI runs all three on Ruby 3.1 through
4.0. The test suite includes bounded thread/Ractor stress and fault injection
for truncated responses, timeouts, reconnects, Sentinel, and Cluster errors.
Run only the benchmark with:

```sh
bundle exec rake benchmark
```

The suite needs no running Redis: it uses an in-process fake server
(`test/support/fake_redis_server.rb`) that speaks RESP2/RESP3, Sentinel,
Pub/Sub and a three-node Cluster topology. To try a specific Ruby version:

```sh
RBENV_VERSION=4.0.1 rbenv exec bundle exec rake test
```

To exercise the client against a real server, start `redis-server` and run
snippets from the examples above with `bundle exec ruby -Ilib`. A local
cluster for manual checks can be created with three
`redis-server --port 700X --cluster-enabled yes` processes followed by
`redis-cli --cluster create 127.0.0.1:7000 127.0.0.1:7001 127.0.0.1:7002 --cluster-yes`.

The changelog lives in `CHANGELOG.md`; add an entry for every release.

## Publishing

Releases use RubyGems Trusted Publishing. Configure a pending trusted
publisher for `nicolasva/solid-redis`, workflow `release.yml`, environment
`release`, then push a tag matching `SolidRedis::VERSION`.
