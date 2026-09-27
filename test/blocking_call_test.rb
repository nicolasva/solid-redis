# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_redis_server"

class BlockingCallTest < Minitest::Test
  def setup
    @delay = 0.0
    @server = FakeRedisServer.new do |command|
      case command.first
      when "BLPOP"
        sleep(@delay)
        @delay.positive? ? ["jobs", "payload"] : nil
      when "PING" then FakeRedisServer::Simple.new("PONG")
      when "HANG"
        sleep(10)
        nil
      else FakeRedisServer::Error.new("ERR unsupported")
      end
    end
    @config = SolidRedis.config(port: @server.port, timeout: 0.1, reconnect_attempts: 1)
  end

  def teardown
    @server.stop
  end

  def test_waits_longer_than_the_regular_read_timeout
    @delay = 0.3
    client = @config.new_client

    assert_equal ["jobs", "payload"], client.blocking_call(1, "BLPOP", "jobs", 1)
    assert_equal "PONG", client.call("PING")
  ensure
    client&.close
  end

  def test_regular_call_would_time_out_on_the_same_wait
    @delay = 0.3
    client = @config.new_client

    assert_raises(SolidRedis::TimeoutError) { client.call("BLPOP", "jobs", 1) }
  ensure
    client&.close
  end

  def test_nil_result_when_redis_times_out
    client = @config.new_client

    assert_nil client.blocking_call(1, "BLPOP", "jobs", 1)
  ensure
    client&.close
  end

  def test_times_out_after_redis_timeout_plus_read_timeout
    client = @config.new_client
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    assert_raises(SolidRedis::TimeoutError) { client.blocking_call(0.2, "HANG") }
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_in_delta 0.3, elapsed, 0.15
    refute client.connected?
  ensure
    client&.close
  end

  def test_connection_error_is_never_retried
    client = @config.new_client
    client.call("PING")
    connections_before = @server.connection_count
    Thread.new { sleep 0.1; @server.stop }

    assert_raises(SolidRedis::ConnectionError) { client.blocking_call(5, "HANG") }
    assert_equal connections_before, @server.connection_count
    refute client.connected?
  ensure
    client&.close
  end

  def test_pool_delegates_blocking_calls
    @delay = 0.3
    pool = @config.new_pool(size: 1)

    assert_equal ["jobs", "payload"], pool.blocking_call(1, "BLPOP", "jobs", 1)
  ensure
    pool&.close
  end
end
