# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "solid_redis"
require_relative "../test/support/fake_redis_server"

operations = Integer(ENV.fetch("BENCHMARK_OPERATIONS", 2_000))
server = FakeRedisServer.new do |command|
  command.first == "PING" ? FakeRedisServer::Simple.new("PONG") : FakeRedisServer::Error.new("ERR unsupported")
end
config = SolidRedis.config(port: server.port, timeout: 2.0)

measure = lambda do |label, count, &work|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  work.call
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  rate = count / elapsed
  puts format("%-24s %10.0f ops/s (%d operations in %.3fs)", label, rate, count, elapsed)
end

client = config.new_client
measure.call("direct calls", operations) do
  operations.times { raise "unexpected response" unless client.call("PING") == "PONG" }
end
client.close

batch_size = 50
batches = (operations.to_f / batch_size).ceil
pipeline_operations = batches * batch_size
client = config.new_client
measure.call("pipeline (50)", pipeline_operations) do
  batches.times do
    replies = client.pipelined do |pipeline|
      batch_size.times { pipeline.call("PING") }
    end
    raise "unexpected pipeline response" unless replies == ["PONG"] * batch_size
  end
end
client.close

threads = 4
per_thread = (operations.to_f / threads).ceil
pool_operations = threads * per_thread
pool = config.new_pool(size: threads, timeout: 2.0)
measure.call("pool (4 threads)", pool_operations) do
  workers = threads.times.map do
    Thread.new do
      per_thread.times { raise "unexpected response" unless pool.call("PING") == "PONG" }
    end
  end
  workers.each(&:value)
end
pool.close
server.stop
