# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_redis_server"

class ClusterTest < Minitest::Test
  # Three fake masters; slot ownership is decided by a shared mutable table so
  # tests can simulate MOVED redirections and resharding.
  def setup
    @store = {}
    @table = Mutex.new
    @scripted_replies = {}
    @nodes = 3.times.map { |index| fake_node(index) }
    @owner = Array.new(SolidRedis::Cluster::KeySlot::SLOTS) { |slot| [slot * 3 / SolidRedis::Cluster::KeySlot::SLOTS, 2].min }
    @ranges = @owner.each_index.chunk_while { |a, b| @owner[a] == @owner[b] }.map { |slots| [slots.first, slots.last, @owner[slots.first]] }
    @config = SolidRedis.cluster(nodes: ["127.0.0.1:#{@nodes[0].port}"], timeout: 0.5)
  end

  def teardown
    @nodes.each(&:stop)
  end

  def test_specification_is_shareable_and_state_is_local
    assert Ractor.shareable?(@config)
    refute @config.discovered?

    client = @config.new_client
    assert_equal "OK", client.call("SET", "foo", "1")
    assert @config.discovered?

    result = ractor_result(Ractor.new(@config) { |config| c = config.new_client; v = c.call("GET", "foo"); c.close; v })
    assert_equal "1", result
    # The other Ractor discovered the topology on its own.
    assert_equal 2, @nodes.sum { |node| node.commands.count { |command| command == %w[CLUSTER SLOTS] } }
  ensure
    client&.close
  end

  def test_routes_keys_to_the_owning_node
    client = @config.new_client
    keys = %w[foo bar baz qux quux corge grault]
    keys.each { |key| client.call("SET", key, key) }

    keys.each do |key|
      owner = @owner[SolidRedis::Cluster::KeySlot.for(key)]
      assert_includes @nodes[owner].commands, ["SET", key, key]
    end
    assert_equal keys, keys.map { |key| client.call("GET", key) }
    assert_equal 3, @nodes.count { |node| node.commands.any? { |command| command.first == "SET" } }
  ensure
    client&.close
  end

  def test_follows_moved_and_updates_the_local_table
    client = @config.new_client
    client.call("SET", "foo", "1")
    slot = SolidRedis::Cluster::KeySlot.for("foo")
    previous = @owner[slot]
    target = (previous + 1) % 3
    @table.synchronize { @owner[slot] = target }

    assert_equal "1", client.call("GET", "foo")
    assert_equal @nodes[target].port, @config.state.node_for_slot(slot).port
    assert_equal 1, @nodes[target].commands.count { |command| command == %w[GET foo] }
  ensure
    client&.close
  end

  def test_pipeline_spans_nodes_and_preserves_order
    client = @config.new_client
    keys = %w[foo bar baz qux]
    keys.each_with_index { |key, index| client.call("SET", key, index.to_s) }

    results = client.pipelined do |pipeline|
      keys.each { |key| pipeline.call("GET", key) }
      pipeline.call("GET", "missing")
    end

    assert_equal %w[0 1 2 3] + [nil], results
    assert_operator @nodes.count { |node| node.commands.any? { |command| command.first == "GET" } }, :>=, 2
  ensure
    client&.close
  end

  def test_pipeline_replays_redirected_commands
    client = @config.new_client
    client.call("SET", "foo", "1")
    slot = SolidRedis::Cluster::KeySlot.for("foo")
    @table.synchronize { @owner[slot] = (@owner[slot] + 1) % 3 }

    assert_equal ["1", "PONG"], client.pipelined { |pipeline| pipeline.call("GET", "foo"); pipeline.call("PING") }
  ensure
    client&.close
  end

  def test_pipeline_retries_transient_cluster_errors
    client = @config.new_client
    client.call("SET", "foo", "1")
    owner = @owner[SolidRedis::Cluster::KeySlot.for("foo")]

    %w[TRYAGAIN CLUSTERDOWN].each do |kind|
      @table.synchronize do
        @scripted_replies[[owner, "GET", "foo"]] = [FakeRedisServer::Error.new("#{kind} temporary")]
      end

      assert_equal ["1"], client.pipelined { |pipeline| pipeline.call("GET", "foo") }
    end
  ensure
    client&.close
  end

  def test_tryagain_after_ask_does_not_send_asking_to_refreshed_owner
    client = @config.new_client
    client.call("SET", "foo", "1")
    slot = SolidRedis::Cluster::KeySlot.for("foo")
    owner = @owner[slot]
    target = (owner + 1) % 3

    @table.synchronize do
      @scripted_replies[[owner, "GET", "foo"]] = [
        FakeRedisServer::Error.new("ASK #{slot} 127.0.0.1:#{@nodes[target].port}"),
      ]
      @scripted_replies[[target, "GET", "foo"]] = [FakeRedisServer::Error.new("TRYAGAIN temporary")]
    end

    assert_equal "1", client.call("GET", "foo")
    assert_equal 1, @nodes[target].commands.count { |command| command == ["ASKING"] }
    assert_equal 0, @nodes[owner].commands.count { |command| command == ["ASKING"] }
  ensure
    client&.close
  end

  def test_keyless_commands_and_command_errors
    client = @config.new_client

    assert_equal "PONG", client.call("PING")
    error = assert_raises(SolidRedis::CommandError) { client.call("BOOM") }
    assert_equal "ERR unsupported", error.message
  ensure
    client&.close
  end

  def test_gives_up_after_too_many_redirections
    client = @config.new_client
    slot = SolidRedis::Cluster::KeySlot.for("foo")
    # Every node claims another node owns the slot: an endless redirection loop.
    @table.synchronize { @owner[slot] = :bounce }

    assert_raises(SolidRedis::FailoverError) { client.call("GET", "foo") }
  ensure
    client&.close
  end

  def test_pool_of_cluster_clients
    pool = @config.new_pool(size: 2)

    assert_equal "OK", pool.call("SET", "foo", "1")
    assert_equal "1", pool.call("GET", "foo")
  ensure
    pool&.close
  end

  def test_rejects_non_zero_database
    assert_raises(ArgumentError) { SolidRedis.cluster(nodes: ["127.0.0.1:1"], db: 1) }
  end

  private

  def fake_node(index)
    FakeRedisServer.new do |command|
      name, key = command
      scripted = @table.synchronize { @scripted_replies[[index, *command]]&.shift }
      next scripted if scripted

      case name
      when "CLUSTER" then slots_reply
      when "PING" then FakeRedisServer::Simple.new("PONG")
      when "ASKING" then FakeRedisServer::Simple.new("OK")
      when "SET", "GET", "MGET", "DEL"
        owner = @table.synchronize { @owner[SolidRedis::Cluster::KeySlot.for(key)] }
        if owner == :bounce
          other = (index + 1) % 3
          FakeRedisServer::Error.new("MOVED #{SolidRedis::Cluster::KeySlot.for(key)} 127.0.0.1:#{@nodes[other].port}")
        elsif owner != index
          FakeRedisServer::Error.new("MOVED #{SolidRedis::Cluster::KeySlot.for(key)} 127.0.0.1:#{@nodes[owner].port}")
        else
          execute(command)
        end
      else FakeRedisServer::Error.new("ERR unsupported")
      end
    end
  end

  def execute(command)
    name, key, value = command
    @table.synchronize do
      case name
      when "SET" then @store[key] = value; FakeRedisServer::Simple.new("OK")
      when "GET" then @store[key]
      when "DEL" then @store.delete(key) ? 1 : 0
      end
    end
  end

  # Initial CLUSTER SLOTS reply derived from the initial ownership table.
  def slots_reply
    @ranges.map { |from, to, index| [from, to, ["127.0.0.1", @nodes[index].port, "node-#{index}"]] }
  end
end
