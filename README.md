# Solid Redis

[![Build Status](https://github.com/nicolasva/solid-redis/actions/workflows/ci.yml/badge.svg)](https://github.com/nicolasva/solid-redis/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/solid-redis.svg)](https://rubygems.org/gems/solid-redis)
[![Downloads](https://img.shields.io/gem/dt/solid-redis.svg)](https://rubygems.org/gems/solid-redis)
[![Documentation Status](https://img.shields.io/badge/docs-RubyDoc.info-blue.svg)](https://www.rubydoc.info/gems/solid-redis)

`solid-redis` is a dependency-free Redis client designed around Ractor
isolation. Its Redis and Sentinel specifications are immutable and shareable;
every Ractor creates and retains its own resolution state, mutex, pool,
clients, and sockets.

It does not depend on or patch `redis-client`.

The implementation intentionally composes two small gems from the same
author:

- [`base-service`](https://github.com/nicolasva/base-service) executes each
  Sentinel resolution and returns its immutable result and endpoint errors;
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

Sentinel additionally requires `name` and `sentinels`, and accepts `role`,
`sentinel_username`, `sentinel_password`, `sentinel_ssl`, and
`sentinel_ssl_params`. Sentinel defaults to two reconnect attempts.

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
| `resolved` | Sentinel name and resolved server URL |

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

- Clients, pools, sockets, mutexes, and Sentinel runtime state are never
  shared between Ractors.
- Multiple threads in one Ractor share one protected Sentinel resolution.
- Redis command errors are never retried.
- Connection errors may retry a command according to `reconnect_attempts`.
  Applications requiring strict at-most-once semantics should set it to `0`.
- A pool waits up to its checkout timeout and then raises
  `SolidRedis::CheckoutTimeoutError`.
- Pub/Sub, transactions, blocking-call helpers, cluster routing, middleware,
  and an asynchronous actor pool are not part of version `0.1`.

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

## Development

```sh
bundle install
bundle exec rake
```

The default task runs the Minitest suite and builds the gem in `pkg/`.
CI runs the suite on Ruby 3.1 through 4.0.

## Publishing

Releases use RubyGems Trusted Publishing. Configure a pending trusted
publisher for `nicolasva/solid-redis`, workflow `release.yml`, environment
`release`, then push a tag matching `SolidRedis::VERSION`.
