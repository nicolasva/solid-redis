# Changelog

All notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.13] - 2026-10-05

### Changed

- Relicense the project from MIT to LGPL-3.0-or-later.

## [1.0.12] - 2026-10-04

### Changed

- Enable `TCP_NODELAY` on TCP connections so consecutive writes (pipelines,
  Pub/Sub re-subscription) are not delayed by Nagle's algorithm.
- Require `solid-resp-ractor` `~> 0.1.5`. With its parser and encoder
  optimizations,
  the Ruby 4.0.1 loopback comparison improves pipeline throughput by 22.6%,
  19.8% and 14.5% at 1, 4 and 8 Ractors (7.5 → 5.0 allocations/op) and
  GET/SET by 5.5% at 1 Ractor (8.4 → 6.4 allocations/op) with lower CPU.

## [1.0.11] - 2026-10-01

### Changed

- Require `solid-resp-ractor` 0.1.4 to reuse the non-blocking socket read
  buffer and reduce response-read allocations.

## [1.0.10] - 2026-09-30

### Changed

- Require `solid-resp-ractor` 0.1.3 for lower-allocation command encoding,
  response parsing, and socket readiness waits.
- Remove transient allocations from Cluster command normalization and CRC16
  slot calculation.
- Cache Cluster state and bounded key-to-slot lookups, store configurations
  directly in the slot table, and avoid locking stable slot reads.
- Improve Cluster throughput by 2.0% to 4.3% over `redis-cluster-client`
  across 1, 2, and 4 Ractors in the six-run benchmark, with approximately 41%
  fewer allocations per operation.

## [1.0.9] - 2026-09-29

### Changed

- Require `solid-resp-ractor` 0.1.1 for threshold-based buffer compaction.

## [1.0.8] - 2026-09-29

### Changed

- Use `solid-resp-ractor` for RESP2/RESP3 encoding and parsing while
  preserving SolidRedis's existing error classes and `SolidRedis::RESP`
  compatibility API.

## [1.0.7] - 2026-09-29

### Changed

- Document how to install and run the standalone `bench_mark_redis` project
  against a local SolidRedis checkout.
- Document how to regenerate SolidRedis's benchmark tables from the external
  benchmark project.

## [1.0.6] - 2026-09-29

### Changed

- Move the benchmark harness to its own standalone project.
- Remove benchmark-only development dependencies and tasks from SolidRedis.
- Keep the standard CI workflow focused on tests and gem construction.

## [1.0.5] - 2026-09-28

### Changed

- Publish the final six-run benchmark matrix for GET/SET, pipelines,
  Ractor-local pools, Cluster, and forced Sentinel failover using SolidRedis
  1.0.4.
- Make the Sentinel benchmark more reliable with bounded reconnect backoff,
  post-failover recovery validation, and ports outside the ephemeral range.

## [1.0.4] - 2026-09-27

### Changed

- Cache the immutable server key instead of allocating it on every Cluster
  lookup.
- Encode one-level nested command arguments without creating an intermediate
  flattened array.
- Parse RESP data with a buffer cursor and compact only when another socket
  read is required, reducing response-parser allocations.
- Attempt non-blocking socket reads and writes before waiting with `IO.select`,
  while preserving read/write deadlines when the socket would block.

## [1.0.3] - 2026-09-27

### Added

- Deterministic fault-injection and bounded thread/Ractor stress tests in the
  standard CI suite.
- A dependency-free local throughput benchmark run by the default Rake task.
- A reproducible real-Redis comparison with `redis-client` across 1/2/4/8
  Ractors, pipelines, isolated pools, Cluster, and forced Sentinel failover,
  including latency percentiles, CPU, RSS, allocations, and errors.

### Fixed

- Consume complete RESP arrays, maps, sets, pushes, and attributes before
  raising nested Redis errors, preventing connection desynchronization.
- Handle `:wait_writable` during non-blocking reads and discard connections
  after protocol errors without replaying commands.
- Retry `TRYAGAIN` and `CLUSTERDOWN` pipeline replies consistently with direct
  Cluster calls, and clear `ASKING` state before refreshing the topology.
- Route `MEMORY USAGE` to the node owning its key.
- Preserve an explicitly configured `db` when a Redis URL is also provided.

### Changed

- Clarify that Cluster commands are grouped into per-node pipelines rather
  than sent concurrently.

## [1.0.2] - 2026-09-27

### Added

- `CHANGELOG.md` and `changelog_uri` gem metadata.

### Changed

- README: describe the test suite's fake server and how to check against a
  real Redis or local cluster.

## [1.0.1] - 2026-09-27

### Changed

- README: document the Cluster architecture (`ClusterConfig`/`ClusterState`).

## [1.0.0] - 2026-09-27

### Added

- `Client#blocking_call(timeout, *command)` and `#blocking_call_v` for BLPOP,
  BRPOP, BZPOPMIN, XREAD BLOCK and similar commands. The read timeout is
  extended by `timeout`; `nil`/`0` waits forever. Blocking commands are never
  retried. Also available on `Pool`.
- Pub/Sub: `Config#new_subscription` and `SentinelConfig#new_subscription`
  return a `SolidRedis::Subscription` bound to a dedicated connection, with
  `subscribe`/`psubscribe`/`ssubscribe`, `next_message(timeout:)`,
  `each_message`, `ping`, and automatic resubscription after reconnect.
- Redis Cluster: `SolidRedis.cluster(nodes:, max_redirections:, **options)`
  builds a shareable `ClusterConfig`. Each Ractor keeps its own `ClusterState`
  (slot table and per-node clients). `ClusterClient` handles `MOVED`, `ASK`,
  `TRYAGAIN` and `CLUSTERDOWN`, extracts routing keys (hash tags, EVAL/FCALL,
  XREAD STREAMS, ZUNION-style commands) and runs pipelines grouped per node
  while preserving reply order.
- `RESP::Reader#with_timeout` and `#wait_readable`.

## [0.2.1] - 2026-09-27

### Changed

- README: refresh the downloads badge.

## [0.2.0] - 2026-09-27

### Added

- `Client#pipelined(exception: false)` returns `CommandError` instances in
  place instead of raising the first one.

## [0.1.1] - 2026-09-27

### Added

- README usage examples.

### Changed

- Require Ruby >= 3.1; CI runs Ruby 3.1 through 4.0.

## [0.1.0] - 2026-09-27

### Added

- Initial release: immutable, Ractor-shareable `Config` and `SentinelConfig`
  with per-Ractor `SentinelState`, `Client` (RESP2/RESP3, TCP, Unix socket,
  TLS, reconnection), `Pool` owned by a single Ractor, pipelines, and
  lifecycle callbacks via `callback-collection`.

[1.0.11]: https://github.com/nicolasva/solid-redis/compare/v1.0.10...v1.0.11
[1.0.10]: https://github.com/nicolasva/solid-redis/compare/v1.0.9...v1.0.10
[1.0.9]: https://github.com/nicolasva/solid-redis/compare/v1.0.8...v1.0.9
[1.0.8]: https://github.com/nicolasva/solid-redis/compare/v1.0.7...v1.0.8
[1.0.7]: https://github.com/nicolasva/solid-redis/compare/v1.0.6...v1.0.7
[1.0.6]: https://github.com/nicolasva/solid-redis/compare/v1.0.5...v1.0.6
[1.0.5]: https://github.com/nicolasva/solid-redis/compare/v1.0.4...v1.0.5
[1.0.4]: https://github.com/nicolasva/solid-redis/compare/v1.0.3...v1.0.4
[1.0.3]: https://github.com/nicolasva/solid-redis/compare/v1.0.2...v1.0.3
[1.0.2]: https://github.com/nicolasva/solid-redis/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/nicolasva/solid-redis/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/nicolasva/solid-redis/compare/v0.2.1...v1.0.0
[0.2.1]: https://github.com/nicolasva/solid-redis/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/nicolasva/solid-redis/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/nicolasva/solid-redis/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/nicolasva/solid-redis/releases/tag/v0.1.0
