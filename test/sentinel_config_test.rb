# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_redis_server"

class SentinelConfigTest < Minitest::Test
  def setup
    @master = redis_server("master")
    @target_mutex = Mutex.new
    @target_port = @master.port
    @sentinel = sentinel_server
    @config = SolidRedis.sentinel(
      name: "mymaster",
      sentinels: [{ host: "127.0.0.1", port: @sentinel.port }],
      timeout: 0.2,
    )
  end

  def teardown
    @sentinel.stop
    @master.stop
    @new_master&.stop
  end

  def test_specification_is_shareable_but_state_is_local
    assert Ractor.shareable?(@config)

    workers = 3.times.map do
      Ractor.new(@config) do |config|
        pool = config.new_pool(size: 1)
        [pool.call("PING"), config.server_key]
      ensure
        pool&.close
      end
    end

    assert_equal [["PONG", [nil, "127.0.0.1", @master.port]]] * 3, workers.map { |w| ractor_result(w) }
    assert_equal 3, resolution_count
    assert_equal 3, @master.connection_count
  end

  def test_reset_is_local_to_the_calling_ractor
    assert_equal @master.port, @config.port

    worker = Ractor.new(@config) do |config|
      first = config.port
      config.reset
      [first, config.port]
    end
    worker_result = ractor_result(worker)

    assert_equal [@master.port, @master.port], worker_result
    assert_equal 3, resolution_count
    assert @config.resolved?
  end

  def test_connection_error_invalidates_and_resolves_the_new_master
    client = @config.new_client
    assert_equal "PONG", client.call("PING")

    @new_master = redis_server("master")
    @target_mutex.synchronize { @target_port = @new_master.port }
    @master.stop

    assert_equal "PONG", client.call("PING")
    assert_equal @new_master.port, @config.port
    assert_equal 2, resolution_count
  ensure
    client&.close
  end

  def test_role_mismatch_is_rejected
    replica = redis_server("slave")
    @target_mutex.synchronize { @target_port = replica.port }
    @config.reset

    assert_raises(SolidRedis::FailoverError) { @config.new_client.call("PING") }
  ensure
    replica&.stop
  end

  private

  def redis_server(role)
    FakeRedisServer.new do |command|
      case command.first
      when "PING" then FakeRedisServer::Simple.new("PONG")
      when "ROLE" then [role]
      else FakeRedisServer::Error.new("ERR unsupported")
      end
    end
  end

  def sentinel_server
    FakeRedisServer.new do |command|
      case command[1]
      when "get-master-addr-by-name"
        ["127.0.0.1", @target_mutex.synchronize { @target_port }.to_s]
      when "sentinels"
        []
      else
        FakeRedisServer::Error.new("ERR unsupported")
      end
    end
  end

  def resolution_count
    @sentinel.commands.count { |command| command[1] == "get-master-addr-by-name" }
  end
end
