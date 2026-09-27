# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_redis_server"

class ClientTest < Minitest::Test
  def setup
    @server = FakeRedisServer.new do |command|
      case command.first
      when "PING" then FakeRedisServer::Simple.new("PONG")
      when "ECHO" then command[1]
      else FakeRedisServer::Error.new("ERR unsupported")
      end
    end
  end

  def teardown
    @server.stop
  end

  def test_calls_redis_and_reuses_the_socket
    client = SolidRedis.config(port: @server.port).new_client

    assert_equal "PONG", client.call("PING")
    assert_equal "hello", client.call("ECHO", "hello")
    assert_equal 1, @server.connection_count
  ensure
    client&.close
  end

  def test_pipeline_reads_all_responses
    client = SolidRedis.config(port: @server.port).new_client

    results = client.pipelined do |pipeline|
      pipeline.call("PING")
      pipeline.call("ECHO", "value")
    end

    assert_equal ["PONG", "value"], results
  ensure
    client&.close
  end

  def test_pipeline_raises_the_first_command_error_by_default
    client = SolidRedis.config(port: @server.port).new_client

    error = assert_raises(SolidRedis::CommandError) do
      client.pipelined do |pipeline|
        pipeline.call("PING")
        pipeline.call("UNKNOWN")
        pipeline.call("ECHO", "after")
      end
    end

    assert_equal "ERR unsupported", error.message
    # The whole pipeline was still read: the socket stays usable.
    assert_equal "PONG", client.call("PING")
    assert_equal 1, @server.connection_count
  ensure
    client&.close
  end

  def test_pipeline_returns_command_errors_in_place_when_exception_is_false
    client = SolidRedis.config(port: @server.port).new_client

    results = client.pipelined(exception: false) do |pipeline|
      pipeline.call("PING")
      pipeline.call("UNKNOWN")
      pipeline.call("ECHO", "after")
    end

    assert_equal "PONG", results[0]
    assert_instance_of SolidRedis::CommandError, results[1]
    assert_equal "ERR unsupported", results[1].message
    assert_equal "after", results[2]
  ensure
    client&.close
  end
end
