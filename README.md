# Solid Redis

[![Build Status](https://github.com/nicolasva/solid-redis/actions/workflows/ci.yml/badge.svg)](https://github.com/nicolasva/solid-redis/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/solid-redis.svg)](https://rubygems.org/gems/solid-redis)
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

workers.map(&:take) # => ["PONG", "PONG", "PONG", "PONG"]
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

## Publishing

Releases use RubyGems Trusted Publishing. Configure a pending trusted
publisher for `nicolasva/solid-redis`, workflow `release.yml`, environment
`release`, then push a tag matching `SolidRedis::VERSION`.
