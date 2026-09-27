# frozen_string_literal: true

require "fileutils"
require "etc"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require "uri"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "solid_redis"
require "redis_client"
require "redis_cluster_client"

class RedisBenchmarkTopology
  SENTINEL_NAME = "benchmark-master"

  attr_reader :standalone_url, :cluster_urls, :sentinel_endpoint

  def initialize
    @directory = Dir.mktmpdir("solid-redis-benchmark")
    @processes = []
    @server_pids = {}
  end

  def start
    @standalone_url = start_server("standalone")
    @cluster_urls = start_cluster
    start_sentinel
    self
  rescue StandardError
    close
    raise
  end

  def close
    @processes.reverse_each do |pid|
      Process.kill("TERM", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
    FileUtils.remove_entry(@directory) if @directory && File.exist?(@directory)
  end

  def wait_for_failover
    wait_until(15, "Sentinel failover did not stabilize") do
      master = sentinel_master_port
      roles = @redis_ports.to_h { |port| [port, redis_cli(port, "ROLE").lines.first&.strip] }
      replica_port = (@redis_ports - [master]).first
      master && roles[master] == "master" && roles[replica_port] == "slave" &&
        sentinel_replica_ports.include?(replica_port)
    end
  rescue RuntimeError => error
    roles = @redis_ports.to_h { |port| [port, redis_cli(port, "ROLE").lines.first&.strip] }
    raise error.class,
      "#{error.message}; master=#{sentinel_master_port.inspect}, roles=#{roles.inspect}, " \
        "sentinel_replicas=#{sentinel_replica_ports.inspect}"
  end

  def sentinel_master_pid
    @server_pids.fetch(sentinel_master_port)
  end

  def reset_sentinel
    stop_process(@sentinel_pid)
    @redis_ports.each do |port|
      stop_process(@server_pids.delete(port))
    end
    start_sentinel
  end

  private

  def start_server(name, extra = [], port: reserve_port)
    directory = File.join(@directory, name)
    FileUtils.mkdir_p(directory)
    command = [
      "redis-server",
      "--port", port.to_s,
      "--bind", "127.0.0.1",
      "--protected-mode", "no",
      "--save", "",
      "--appendonly", "no",
      "--dir", directory,
      *extra,
    ]
    pid = Process.spawn(*command, out: File.join(directory, "redis.log"), err: [:child, :out])
    @processes << pid
    @server_pids[port] = pid
    wait_for_redis(port)
    "redis://127.0.0.1:#{port}"
  end

  def start_cluster
    urls = 3.times.map do |index|
      port = reserve_cluster_port
      start_server(
        "cluster-#{index}",
        [
          "--cluster-enabled", "yes",
          "--cluster-config-file", "nodes.conf",
          "--cluster-node-timeout", "1000",
        ],
        port: port,
      )
    end
    success = system(
      "redis-cli", "--cluster", "create", *urls.map { |url| URI(url).then { |uri| "#{uri.host}:#{uri.port}" } },
      "--cluster-replicas", "0", "--cluster-yes",
      out: File::NULL, err: File::NULL,
    )
    raise "failed to create Redis Cluster" unless success

    urls
  end

  def start_sentinel
    master_url = start_server("sentinel-master")
    master_port = URI(master_url).port
    replica_url = start_server("sentinel-replica", ["--replicaof", "127.0.0.1", master_port.to_s])
    replica_port = URI(replica_url).port
    @redis_ports = [master_port, replica_port]

    sentinel_port = reserve_port
    sentinel_directory = File.join(@directory, "sentinel")
    FileUtils.mkdir_p(sentinel_directory)
    config = File.join(sentinel_directory, "sentinel.conf")
    File.write(config, <<~CONFIG)
      port #{sentinel_port}
      bind 127.0.0.1
      protected-mode no
      daemonize no
      dir #{sentinel_directory}
      sentinel monitor #{SENTINEL_NAME} 127.0.0.1 #{master_port} 1
      sentinel down-after-milliseconds #{SENTINEL_NAME} 200
      sentinel failover-timeout #{SENTINEL_NAME} 1000
      sentinel parallel-syncs #{SENTINEL_NAME} 1
    CONFIG
    @sentinel_pid = Process.spawn(
      "redis-server", config, "--sentinel",
      out: File.join(sentinel_directory, "redis.log"),
      err: [:child, :out],
    )
    @processes << @sentinel_pid
    wait_for_redis(sentinel_port)
    @sentinel_endpoint = { "host" => "127.0.0.1", "port" => sentinel_port }
    wait_for_failover
  end

  def sentinel_master_port
    output = redis_cli(
      sentinel_endpoint.fetch("port"),
      "SENTINEL", "get-master-addr-by-name", SENTINEL_NAME,
    )
    Integer(output.lines[1], exception: false)
  end

  def sentinel_replica_ports
    output, = Open3.capture3(
      "redis-cli", "-h", "127.0.0.1",
      "-p", sentinel_endpoint.fetch("port").to_s,
      "--json", "SENTINEL", "replicas", SENTINEL_NAME,
    )
    Array(JSON.parse(output)).filter_map do |entry|
      replica = entry.is_a?(Hash) ? entry : Hash[*entry]
      flags = replica.fetch("flags", "").split(",")
      next if flags.any? { |flag| %w[s_down o_down disconnected].include?(flag) }
      next unless replica["master-link-status"] == "ok"

      Integer(replica["port"], exception: false)
    end
  rescue JSON::ParserError
    []
  end

  def wait_for_redis(port)
    wait_until(5, "Redis on port #{port} did not start") do
      redis_cli(port, "PING").strip == "PONG"
    end
  end

  def redis_running?(port)
    redis_cli(port, "PING").strip == "PONG"
  end

  def stop_process(pid)
    return unless pid

    Process.kill("TERM", pid)
  rescue Errno::ESRCH
    nil
  ensure
    begin
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
    @processes.delete(pid)
  end

  def wait_until(timeout, message)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return if yield
      raise message if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    rescue StandardError
      raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def redis_cli(port, *command)
    stdout, = Open3.capture3("redis-cli", "-h", "127.0.0.1", "-p", port.to_s, "--raw", *command)
    stdout
  end

  def reserve_port
    server = TCPServer.new("127.0.0.1", 0)
    server.local_address.ip_port
  ensure
    server&.close
  end

  def reserve_cluster_port
    loop do
      port = rand(20_000..39_000)
      server = TCPServer.new("127.0.0.1", port)
      bus_server = TCPServer.new("127.0.0.1", port + 10_000)
      return port
    rescue Errno::EADDRINUSE
      next
    ensure
      server&.close
      bus_server&.close
    end
  end
end

class ComparisonBenchmark
  CLIENTS = ["redis-client", "solid-redis"].freeze
  RACTORS = [1, 2, 4, 8].freeze
  SCENARIOS = ["get-set", "pipeline", "ractor-pool", "cluster", "sentinel"].freeze

  def initialize
    @warmup_duration = Float(ENV.fetch("BENCHMARK_WARMUP", 2.0))
    @measurement_duration = Float(ENV.fetch("BENCHMARK_DURATION", 10.0))
    @repetitions = Integer(ENV.fetch("BENCHMARK_REPETITIONS", 6))
    @pool_warmup_operations = Integer(ENV.fetch("BENCHMARK_POOL_WARMUP", 1_000))
    @pool_operations = Integer(ENV.fetch("BENCHMARK_POOL_OPERATIONS", 100_000))
    @scenarios = ENV.fetch("BENCHMARK_SCENARIOS", SCENARIOS.join(",")).split(",")
    @ractors = ENV.fetch("BENCHMARK_RACTORS", RACTORS.join(",")).split(",").map { |value| Integer(value) }
    @topology = RedisBenchmarkTopology.new.start
  end

  def run
    results = @scenarios.flat_map do |scenario|
      @ractors.flat_map do |ractors|
        runs = CLIENTS.to_h { |client| [client, []] }
        @repetitions.times do |repeat|
          order = repeat.even? ? CLIENTS : CLIENTS.reverse
          order.each do |client|
            next if runs.fetch(client).first&.key?("unsupported_reason")

            warn "Benchmarking #{scenario}, #{ractors} Ractor(s), #{client} (#{repeat + 1}/#{@repetitions})..."
            runs.fetch(client) << run_case(client, scenario, ractors)
            @topology.reset_sentinel if scenario == "sentinel"
          end
        end
        CLIENTS.map do |client|
          aggregate(runs.fetch(client))
            .merge("client" => client, "scenario" => scenario, "ractors" => ractors)
        end
      end
    end
    output = render(results)
    if (path = ENV["BENCHMARK_README"])
      publish_readme(path, output)
    elsif (path = ENV["BENCHMARK_OUTPUT"])
      File.write(path, output)
    else
      puts output
    end
  ensure
    @topology.close
  end

  private

  def run_case(client, scenario, ractors)
    settings = {
      "client" => client,
      "scenario" => scenario,
      "ractors" => ractors,
      "batch_size" => 50,
      "warmup_duration" => @warmup_duration,
      "measurement_duration" => @measurement_duration,
      "pool_size" => 5,
      "pool_warmup_operations" => @pool_warmup_operations,
      "pool_operations" => @pool_operations,
      "failover_delay" => 0.5,
      "sentinel_master_pid" => @topology.sentinel_master_pid,
      "standalone_url" => @topology.standalone_url,
      "cluster_urls" => @topology.cluster_urls,
      "sentinel_name" => RedisBenchmarkTopology::SENTINEL_NAME,
      "sentinel_endpoint" => @topology.sentinel_endpoint,
    }
    stdout, stderr, status = Open3.capture3(
      { "SOLID_REDIS_BENCHMARK" => JSON.generate(settings) },
      *timed_worker_command,
    )
    unless status.success?
      if scenario == "ractor-pool" && client == "redis-client" &&
          stderr.include?("Ractor::IsolationError") && stderr.include?("ConnectionPool::INSTANCES")
        return {
          "unsupported_reason" =>
            "Ractor::IsolationError (`connection_pool` uses non-shareable global state)",
        }
      end
      raise "benchmark failed:\n#{stdout}\n#{stderr}"
    end

    result = JSON.parse(stdout.lines.last)
    result["peak_rss_mb"] = parse_peak_rss(stderr) || result["peak_rss_mb"]
    raise "peak RSS measurement is unavailable" unless result["peak_rss_mb"]

    result
  end

  def timed_worker_command
    worker = File.expand_path("comparison_worker.rb", __dir__)
    if File.executable?("/usr/bin/time") && RUBY_PLATFORM.include?("darwin")
      ["/usr/bin/time", "-l", RbConfig.ruby, worker]
    elsif File.executable?("/usr/bin/time") && RUBY_PLATFORM.include?("linux")
      ["/usr/bin/time", "-v", RbConfig.ruby, worker]
    else
      [RbConfig.ruby, worker]
    end
  end

  def parse_peak_rss(output)
    if RUBY_PLATFORM.include?("darwin")
      bytes = output[/(\d+)\s+maximum resident set size/, 1]
      Integer(bytes) / 1_048_576.0 if bytes
    else
      kilobytes = output[/Maximum resident set size \(kbytes\):\s*(\d+)/, 1]
      Integer(kilobytes) / 1_024.0 if kilobytes
    end
  end

  def render(results)
    metadata = [
      "Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM})",
      "solid-redis #{SolidRedis::VERSION}",
      `redis-server --version`.strip,
      "redis-client #{Gem.loaded_specs.fetch("redis-client").version}",
      "redis-cluster-client #{Gem.loaded_specs.fetch("redis-cluster-client").version}",
      machine_description,
    ]
    sections = @scenarios.map do |scenario|
      rows = results.select { |result| result.fetch("scenario") == scenario }
      header = if scenario == "sentinel"
        "| Ractors | Client | Throughput (ops/s) | p50 (ms) | p95 (ms) | p99 (ms) | Recovery p50 (ms) | Recovery max (ms) | CPU | Peak RSS | Allocations/op | Errors/run |"
      else
        "| Ractors | Client | Throughput (ops/s) | p50 (ms) | p95 (ms) | p99 (ms) | CPU | Peak RSS | Allocations/op | Errors/run |"
      end
      separator = if scenario == "sentinel"
        "|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
      else
        "|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|"
      end
      [
        "### #{scenario_label(scenario)}",
        "",
        header,
        separator,
        *rows.map { |result| render_row(result, sentinel: scenario == "sentinel") },
      ].join("\n")
    end
    <<~MARKDOWN
      <!-- benchmark-results:start -->
      This is a local-loopback microbenchmark, not a prediction of application
      performance. It excludes Redis server CPU/RAM and network latency.
      Cluster rows compare `solid-redis` with `redis-cluster-client`, the
      Cluster implementation built on `redis-client`. Unsupported combinations
      are reported rather than replaced with a different concurrency model.

      **Environment:** #{metadata.join("; ")}.

      Each row is measured in a fresh Ruby process. Both clients use RESP2,
      identical commands and the same local Redis topology. Client order is
      alternated between runs; values are medians of #{@repetitions} runs.
      Regular workloads warm for #{@warmup_duration.to_i} seconds and measure
      for #{@measurement_duration.to_i} seconds. Pipeline latency is amortized
      per command (batch size 50). The isolated-pool scenario creates a
      five-connection pool inside each Ractor, warms it with
      #{integer_with_delimiter(@pool_warmup_operations)} PINGs, then measures
      #{integer_with_delimiter(@pool_operations)}
      PINGs per Ractor.
      CPU is client-process CPU divided by wall time and may exceed 100% with
      multiple Ractors. Peak RSS excludes Redis server processes. Sentinel
      rows kill the master process 0.5 seconds after measurement starts and
      verify that every Ractor resumes on the promoted replica. Recovery is
      measured from each Ractor's first observed failure to its next successful
      response.
      Throughput counts successful commands; errors are failed commands
      observed during the measured interval.
      Allocation and RSS measurements include the identical sampled-latency
      harness used for both clients, so they are comparative rather than
      intrinsic library-only costs. `redis-cluster-client` uses its default
      synchronous routing model (`concurrency: { model: :none }`).

      Reproduce the full run (requires `redis-server` and `redis-cli`):

      ```sh
      BENCHMARK_README=README.md bundle exec rake benchmark:comparison
      ```

      #{sections.join("\n\n")}
      <!-- benchmark-results:end -->
    MARKDOWN
  end

  def render_row(result, sentinel:)
    if (reason = result["unsupported_reason"])
      columns = sentinel ? 12 : 10
      values = [result.fetch("ractors"), "`#{result.fetch("client")}`", "unsupported: #{reason}"]
      values.concat(["—"] * (columns - values.length))
      return "| #{values.join(" | ")} |"
    end

    values = [
      result.fetch("ractors"),
      result.fetch("client"),
      integer_with_delimiter(result.fetch("throughput").round),
      result.fetch("p50_ms"),
      result.fetch("p95_ms"),
      result.fetch("p99_ms"),
    ]
    if sentinel
      values << result.fetch("recovery_p50_ms")
      values << result.fetch("recovery_max_ms")
    end
    values.concat([
      result.fetch("cpu_percent"),
      result.fetch("peak_rss_mb"),
      result.fetch("allocations_per_operation"),
      result.fetch("errors"),
    ])
    template = if sentinel
      "| %d | `%s` | %s | %.3f | %.3f | %.3f | %.1f | %.1f | %.1f%% | %.1f MiB | %.1f | %d |"
    else
      "| %d | `%s` | %s | %.3f | %.3f | %.3f | %.1f%% | %.1f MiB | %.1f | %d |"
    end
    format(template, *values)
  end

  def aggregate(runs)
    return runs.first if runs.first&.key?("unsupported_reason")

    keys = %w[
      throughput p50_ms p95_ms p99_ms cpu_percent peak_rss_mb
      allocations_per_operation errors operations elapsed recovery_p50_ms
      recovery_max_ms
    ]
    keys.to_h { |key| [key, median(runs.map { |run| run.fetch(key) })] }
  end

  def median(values)
    sorted = values.sort
    middle = sorted.length / 2
    sorted.length.odd? ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2.0
  end

  def machine_description
    if RUBY_PLATFORM.include?("darwin")
      cpu = `sysctl -n machdep.cpu.brand_string`.strip
      cores = `sysctl -n hw.ncpu`.strip
      memory = Integer(`sysctl -n hw.memsize`) / (1024**3)
      os = "macOS #{`sw_vers -productVersion`.strip}"
    else
      cpu = File.read("/proc/cpuinfo")[/^model name\s*:\s*(.+)$/, 1] || "unknown CPU"
      cores = Etc.nprocessors
      memory = File.read("/proc/meminfo")[/^MemTotal:\s*(\d+)/, 1].to_i / (1024**2)
      os = RbConfig::CONFIG["host_os"]
    end
    "#{cpu}, #{cores} logical CPUs, #{memory} GiB RAM, #{os}"
  end

  def publish_readme(path, output)
    content = File.read(path)
    section = "## Benchmark\n\n#{output.rstrip}"
    if content.include?("<!-- benchmark-results:start -->")
      replaced = content.sub!(
        /## Benchmark\n\n<!-- benchmark-results:start -->.*?<!-- benchmark-results:end -->/m,
        section,
      )
    else
      replaced = content.sub!("\n## Development", "\n#{section}\n\n## Development")
    end
    raise "README benchmark insertion point not found" unless replaced

    File.write(path, content)
  end

  def scenario_label(scenario)
    {
      "get-set" => "GET / SET",
      "pipeline" => "Pipelines",
      "ractor-pool" => "Isolated pool per Ractor",
      "cluster" => "Cluster",
      "sentinel" => "Sentinel master crash",
    }.fetch(scenario)
  end

  def integer_with_delimiter(value)
    value.to_s.reverse.scan(/.{1,3}/).join(",").reverse
  end
end

ComparisonBenchmark.new.run
