# frozen_string_literal: true

require "json"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "solid_redis"
require "redis_client"
require "redis_cluster_client"

module ComparisonWorker
  module_function

  def run
    settings = JSON.parse(ENV.fetch("SOLID_REDIS_BENCHMARK"))
    workers = build_workers(settings)
    wait_until_ready(workers)

    GC.start
    allocations_before = GC.stat(:total_allocated_objects)
    cpu_before = process_cpu
    started = monotonic_time
    release(workers, started)
    kill_sentinel_master(settings, started) if settings["scenario"] == "sentinel"
    wait_until_done(workers)
    elapsed = monotonic_time - started
    cpu = process_cpu - cpu_before
    allocations = GC.stat(:total_allocated_objects) - allocations_before
    results = collect(workers)

    latencies = results.flat_map { |result| result.fetch("latencies") }.sort
    successes = results.sum { |result| result.fetch("successes") }
    errors = results.sum { |result| result.fetch("errors") }
    recoveries = results.filter_map { |result| result["recovery_ms"] }.sort
    if settings["scenario"] == "sentinel" && recoveries.length != settings.fetch("ractors")
      raise "not every Ractor recovered after Sentinel failover"
    end
    puts JSON.generate(
      throughput: successes / elapsed,
      p50_ms: percentile(latencies, 0.50),
      p95_ms: percentile(latencies, 0.95),
      p99_ms: percentile(latencies, 0.99),
      cpu_percent: cpu / elapsed * 100,
      allocations_per_operation: successes.zero? ? 0 : allocations.to_f / successes,
      errors: errors,
      operations: successes,
      elapsed: elapsed,
      recovery_p50_ms: percentile(recoveries, 0.50),
      recovery_max_ms: recoveries.last || 0,
      peak_rss_mb: peak_rss_mb,
    )
  end

  def build_workers(settings)
    ractors = settings.fetch("ractors")
    if defined?(Ractor::Port)
      ready = Ractor::Port.new
      start = Ractor::Port.new
      done = Ractor::Port.new
      list = ractors.times.map do |index|
        Ractor.new(settings, index, ready, start, done) do |options, worker_index, ready_port, start_port, done_port|
          client = ComparisonWorker.build_client(options)
          ComparisonWorker.warm(client, options, worker_index)
          ready_port << true
          measurement_started = start_port.receive
          result = ComparisonWorker.measure(client, options, worker_index, measurement_started)
          done_port << true
          result
        ensure
          client&.close
        end
      end
      { list: list, ready: ready, start: start, done: done }
    else
      list = ractors.times.map do |index|
        Ractor.new(settings, index) do |options, worker_index|
          client = ComparisonWorker.build_client(options)
          ComparisonWorker.warm(client, options, worker_index)
          Ractor.yield(:ready)
          measurement_started = Ractor.receive
          result = ComparisonWorker.measure(client, options, worker_index, measurement_started)
          Ractor.yield(:done)
          result
        ensure
          client&.close
        end
      end
      { list: list }
    end
  end

  def wait_until_ready(workers)
    if workers[:ready]
      workers[:list].length.times { workers[:ready].receive }
    else
      workers[:list].each do |worker|
        raise "benchmark worker failed to initialize" unless worker.take == :ready
      end
    end
  end

  def release(workers, started)
    if workers[:start]
      workers[:list].length.times { workers[:start] << started }
    else
      workers[:list].each { |worker| worker.send(started) }
    end
  end

  def collect(workers)
    if workers[:start]
      workers[:list].map(&:value)
    else
      workers[:list].map(&:take)
    end
  end

  def wait_until_done(workers)
    if workers[:done]
      workers[:list].length.times { workers[:done].receive }
    else
      workers[:list].each do |worker|
        raise "benchmark worker failed during measurement" unless worker.take == :done
      end
    end
  end

  def build_client(settings)
    client = settings.fetch("client")
    scenario = settings.fetch("scenario")
    case [client, scenario]
    when ["solid-redis", "cluster"]
      SolidRedis.cluster(
        nodes: settings.fetch("cluster_urls"),
        timeout: 1.0,
        reconnect_attempts: 2,
      ).new_client
    when ["redis-client", "cluster"]
      RedisClient.cluster(
        nodes: settings.fetch("cluster_urls"),
        protocol: 2,
        timeout: 1.0,
        reconnect_attempts: 2,
        concurrency: { model: :none },
      ).new_client
    when ["solid-redis", "sentinel"]
      SolidRedis.sentinel(
        name: settings.fetch("sentinel_name"),
        sentinels: [settings.fetch("sentinel_endpoint")],
        timeout: 0.2,
        reconnect_attempts: 2,
      ).new_client
    when ["redis-client", "sentinel"]
      sentinel = settings.fetch("sentinel_endpoint")
      RedisClient.sentinel(
        name: settings.fetch("sentinel_name"),
        sentinels: [{ host: sentinel.fetch("host"), port: sentinel.fetch("port") }],
        role: :master,
        protocol: 2,
        timeout: 0.2,
        reconnect_attempts: 2,
      ).new_client
    when ["solid-redis", "ractor-pool"]
      SolidRedis.config(url: settings.fetch("standalone_url"), timeout: 1.0)
        .new_pool(size: settings.fetch("pool_size"), timeout: 1.0)
    when ["redis-client", "ractor-pool"]
      RedisClient.config(
        url: settings.fetch("standalone_url"),
        protocol: 2,
        timeout: 1.0,
      ).new_pool(size: settings.fetch("pool_size"), timeout: 1.0)
    else
      case client
      when "solid-redis"
        SolidRedis.config(url: settings.fetch("standalone_url"), timeout: 1.0).new_client
      when "redis-client"
        RedisClient.config(
          url: settings.fetch("standalone_url"),
          protocol: 2,
          timeout: 1.0,
        ).new_client
      else
        raise "unknown benchmark combination: #{client}/#{scenario}"
      end
    end
  end

  def warm(client, settings, worker_index)
    key = "benchmark:warm:#{worker_index}"
    if settings["scenario"] == "ractor-pool"
      settings.fetch("pool_warmup_operations").times do
        raise "benchmark warmup failed" unless client.call("PING") == "PONG"
      end
      return
    end

    deadline = monotonic_time + settings.fetch("warmup_duration")
    index = 0
    while monotonic_time < deadline
      if settings["scenario"] == "pipeline"
        client.pipelined do |pipeline|
          settings.fetch("batch_size").times { pipeline.call("PING") }
        end
      else
        index.even? ? client.call("SET", key, index) : client.call("GET", key)
      end
      index += 1
    end
  end

  def measure(client, settings, worker_index, measurement_started)
    case settings.fetch("scenario")
    when "pipeline"
      measure_pipeline(client, settings, worker_index)
    when "sentinel"
      measure_until_deadline(client, settings, worker_index, measurement_started)
    when "ractor-pool"
      measure_pool(client, settings)
    else
      measure_commands(client, settings, worker_index)
    end
  end

  def measure_commands(client, settings, worker_index)
    latencies = []
    successes = 0
    errors = 0
    deadline = monotonic_time + settings.fetch("measurement_duration")
    index = 0
    while monotonic_time < deadline
      key = "benchmark:#{worker_index}:#{index % 128}"
      started = monotonic_time
      begin
        index.even? ? client.call("SET", key, index) : client.call("GET", key)
        successes += 1
        record_latency(latencies, index, started)
      rescue StandardError
        errors += 1
      end
      index += 1
    end
    { "latencies" => latencies, "successes" => successes, "errors" => errors }
  end

  def measure_pipeline(client, settings, worker_index)
    batch_size = settings.fetch("batch_size")
    deadline = monotonic_time + settings.fetch("measurement_duration")
    latencies = []
    successes = 0
    errors = 0
    batch = 0
    while monotonic_time < deadline
      started = monotonic_time
      begin
        replies = client.pipelined do |pipeline|
          batch_size.times do |index|
            key = "benchmark:#{worker_index}:#{(batch * batch_size + index) % 128}"
            index.even? ? pipeline.call("SET", key, index) : pipeline.call("GET", key)
          end
        end
        successes += replies.length
        per_operation = (monotonic_time - started) * 1_000 / replies.length
        record_latency(latencies, batch, started, elapsed_ms: per_operation)
      rescue StandardError
        errors += batch_size
      end
      batch += 1
    end
    { "latencies" => latencies, "successes" => successes, "errors" => errors }
  end

  def measure_until_deadline(client, settings, worker_index, measurement_started)
    deadline = measurement_started + settings.fetch("measurement_duration")
    failure_at = measurement_started + settings.fetch("failover_delay")
    latencies = []
    successes = 0
    errors = 0
    recovery_ms = nil
    failure_started = nil
    index = 0
    while monotonic_time < deadline
      key = "benchmark:failover:#{worker_index}:#{index % 128}"
      started = monotonic_time
      begin
        index.even? ? client.call("SET", key, index) : client.call("GET", key)
        successes += 1
        completed = monotonic_time
        record_latency(latencies, index, started, completed: completed)
        recovery_ms ||= (completed - failure_started) * 1_000 if failure_started
      rescue StandardError
        errors += 1
        failure_started ||= monotonic_time if monotonic_time >= failure_at
      end
      index += 1
    end
    {
      "latencies" => latencies,
      "successes" => successes,
      "errors" => errors,
      "recovery_ms" => recovery_ms,
    }
  end

  def measure_pool(client, settings)
    latencies = []
    successes = 0
    errors = 0
    settings.fetch("pool_operations").times do
      started = monotonic_time
      begin
        raise "unexpected PING response" unless client.call("PING") == "PONG"

        successes += 1
        record_latency(latencies, successes, started)
      rescue StandardError
        errors += 1
      end
    end
    { "latencies" => latencies, "successes" => successes, "errors" => errors }
  end

  def kill_sentinel_master(settings, measurement_started)
    delay = measurement_started + settings.fetch("failover_delay") - monotonic_time
    sleep(delay) if delay.positive?
    Process.kill("KILL", settings.fetch("sentinel_master_pid"))
  end

  def record_latency(latencies, index, started, completed: nil, elapsed_ms: nil)
    return unless (index % 100).zero?

    latencies << (elapsed_ms || ((completed || monotonic_time) - started) * 1_000)
  end

  def percentile(values, ratio)
    return 0 if values.empty?

    values[[(values.length * ratio).ceil - 1, 0].max]
  end

  def process_cpu
    times = Process.times
    times.utime + times.stime
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def peak_rss_mb
    return unless File.readable?("/proc/self/status")

    kilobytes = File.read("/proc/self/status")[/^VmHWM:\s*(\d+)/, 1]
    Integer(kilobytes) / 1_024.0 if kilobytes
  end
end

ComparisonWorker.run
