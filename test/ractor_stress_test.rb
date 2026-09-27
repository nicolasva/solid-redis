# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_redis_server"

# Stress tests combining several Ractors, several threads per Ractor, and
# per-Ractor pools. On CRuby < 4.0 the VM scheduler can hang intermittently
# when multiple Ractors each run multiple threads, so these tests only run
# on Ruby >= 4.0.
class RactorStressTest < Minitest::Test
  RACTORS = 4
  THREADS = 3
  PINGS = 30

  def setup
    skip "multi-thread × multi-Ractor hangs in CRuby < 4.0" if RUBY_VERSION < "4.0"

    @master = FakeRedisServer.new do |command|
      case command.first
      when "PING" then FakeRedisServer::Simple.new("PONG")
      when "ROLE" then ["master"]
      else FakeRedisServer::Error.new("ERR unsupported")
      end
    end
    @sentinel = FakeRedisServer.new do |command|
      case command[1]
      when "get-master-addr-by-name" then ["127.0.0.1", @master.port.to_s]
      when "sentinels" then []
      else FakeRedisServer::Error.new("ERR unsupported")
      end
    end
    @config = SolidRedis.sentinel(
      name: "mymaster",
      sentinels: [{ host: "127.0.0.1", port: @sentinel.port }],
      timeout: 1.0,
    )
  end

  def teardown
    @sentinel&.stop
    @master&.stop
  end

  def test_many_ractors_each_running_many_threads_over_a_pool
    workers = RACTORS.times.map do
      Ractor.new(@config, THREADS, PINGS) do |config, threads, pings|
        pool = config.new_pool(size: 2, timeout: 5.0)
        begin
          threads.times.map do
            Thread.new { pings.times.count { pool.call("PING") == "PONG" } }
          end.sum(&:value)
        ensure
          pool.close
        end
      end
    end

    assert_equal [THREADS * PINGS] * RACTORS, workers.map { |w| ractor_result(w) }
    # One Sentinel resolution per Ractor, never one per thread or per command.
    assert_equal RACTORS, resolution_count
  end

  def test_direct_config_clients_from_many_ractors_and_threads
    config = SolidRedis.config(host: "127.0.0.1", port: @master.port, timeout: 1.0)

    workers = RACTORS.times.map do
      Ractor.new(config, THREADS, PINGS) do |cfg, threads, pings|
        threads.times.map do
          Thread.new do
            client = cfg.new_client
            begin
              pings.times.count { client.call("PING") == "PONG" }
            ensure
              client.close
            end
          end
        end.sum(&:value)
      end
    end

    assert_equal [THREADS * PINGS] * RACTORS, workers.map { |w| ractor_result(w) }
  end

  private

  def resolution_count
    @sentinel.commands.count { |command| command[1] == "get-master-addr-by-name" }
  end
end
