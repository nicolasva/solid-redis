# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_redis_server"

class FaultInjectionTest < Minitest::Test
  def setup
    @attempts = Hash.new(0)
    @attempts_mutex = Mutex.new
    @server = FakeRedisServer.new do |command|
      attempt = @attempts_mutex.synchronize do
        @attempts[command] += 1
      end

      case command.first
      when "PARTIAL"
        attempt == 1 ? FakeRedisServer::Close.new("$5\r\nab") : "recovered"
      when "SLOW"
        sleep(0.05) if attempt == 1
        "recovered"
      when "FLAKY"
        attempt == 1 ? FakeRedisServer::Close.new : command[1]
      else
        FakeRedisServer::Simple.new("PONG")
      end
    end
  end

  def teardown
    @server.stop
  end

  def test_reconnects_after_response_is_truncated_mid_frame
    client = config.new_client

    assert_equal "recovered", client.call("PARTIAL")
    assert_equal 2, attempts_for(["PARTIAL"])
    assert_equal 2, @server.connection_count
  ensure
    client&.close
  end

  def test_reconnects_after_read_timeout
    client = config.new_client

    assert_equal "recovered", client.call("SLOW")
    assert_equal 2, attempts_for(["SLOW"])
    assert_equal 2, @server.connection_count
  ensure
    client&.close
  end

  def test_pool_survives_repeated_connection_failures_under_contention
    pool = config.new_pool(size: 4, timeout: 2.0)
    threads = 6.times.map do |thread_index|
      Thread.new do
        20.times.map do |iteration|
          token = "#{thread_index}:#{iteration}"
          pool.call("FLAKY", token)
        end
      end
    end

    results = threads.flat_map(&:value)
    assert_equal 120, results.length
    assert_equal 120, results.uniq.length
    assert results.all? { |token| attempts_for(["FLAKY", token]) == 2 }
  ensure
    pool&.close
  end

  private

  def config
    SolidRedis.config(
      port: @server.port,
      connect_timeout: 0.1,
      read_timeout: 0.02,
      write_timeout: 0.1,
      reconnect_attempts: 1,
    )
  end

  def attempts_for(command)
    @attempts_mutex.synchronize { @attempts[command] }
  end
end
