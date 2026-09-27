# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_redis_server"

class PoolTest < Minitest::Test
  def setup
    @server = FakeRedisServer.new do |command|
      case command.first
      when "FAIL" then FakeRedisServer::Error.new("ERR fail")
      when "NESTED_ERROR" then ["before", FakeRedisServer::Error.new("ERR nested"), "after"]
      when "MALFORMED" then FakeRedisServer::Raw.new("?broken\r\n")
      else FakeRedisServer::Simple.new("PONG")
      end
    end
    @pool = SolidRedis.config(port: @server.port).new_pool(size: 2, timeout: 0.05)
  end

  def teardown
    @pool.close
    @server.stop
  end

  def test_reuses_connections_and_delegates_commands
    3.times { assert_equal "PONG", @pool.call("PING") }

    assert_equal 1, @server.connection_count
  end

  def test_pipelined_forwards_the_exception_option
    results = @pool.pipelined(exception: false) do |pipeline|
      pipeline.call("PING")
      pipeline.call("FAIL")
    end

    assert_equal "PONG", results[0]
    assert_instance_of SolidRedis::CommandError, results[1]
    assert_raises(SolidRedis::CommandError) { @pool.pipelined { |pipeline| pipeline.call("FAIL") } }
  end

  def test_nested_error_does_not_poison_client_for_next_borrower
    errors = Queue.new
    borrower = Thread.new do
      @pool.call("NESTED_ERROR")
    rescue SolidRedis::CommandError => error
      errors << error
    end
    borrower.join

    assert_equal "ERR nested", errors.pop.message
    assert_equal "PONG", @pool.call("PING")
    assert_equal 1, @server.connection_count
  end

  def test_protocol_error_discards_client_socket_before_checkin
    assert_raises(SolidRedis::ProtocolError) { @pool.call("MALFORMED") }

    assert_equal "PONG", @pool.call("PING")
    assert_equal 2, @server.connection_count
  end

  def test_times_out_when_all_connections_are_checked_out
    entered = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new do
        @pool.with do
          entered << true
          release.pop
        end
      end
    end
    2.times { entered.pop }

    assert_raises(SolidRedis::CheckoutTimeoutError) { @pool.call("PING") }
  ensure
    2.times { release << true }
    threads&.each(&:join)
  end
end
