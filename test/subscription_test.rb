# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_redis_server"

class SubscriptionTest < Minitest::Test
  def setup
    @server = FakeRedisServer.new do |command|
      command.first == "PING" ? FakeRedisServer::Simple.new("PONG") : FakeRedisServer::Error.new("ERR unsupported")
    end
    @config = SolidRedis.config(port: @server.port, timeout: 0.5, reconnect_attempts: 1)
    @subscription = @config.new_subscription
  end

  def teardown
    @subscription.close
    @server.stop
  end

  def test_receives_channel_and_pattern_messages
    @subscription.subscribe("events").psubscribe("alerts.*")
    confirmations = 2.times.map { @subscription.next_message(timeout: 1) }
    assert_equal %i[subscribe psubscribe], confirmations.map(&:type)

    wait_until { @server.publish("events", "hello") == 1 }
    @server.publish("alerts.cpu", "hot")

    message = @subscription.next_message(timeout: 1)
    assert_equal :message, message.type
    assert_equal "events", message.channel
    assert_equal "hello", message.payload
    assert message.message?

    pmessage = @subscription.next_message(timeout: 1)
    assert_equal :pmessage, pmessage.type
    assert_equal "alerts.*", pmessage.pattern
    assert_equal "alerts.cpu", pmessage.channel
    assert_equal "hot", pmessage.payload
  end

  def test_returns_nil_on_timeout_without_closing
    @subscription.subscribe("events")
    @subscription.next_message(timeout: 1)

    assert_nil @subscription.next_message(timeout: 0.05)
    assert @subscription.connected?
    @subscription.ping("keepalive")
    assert_equal :pong, @subscription.next_message(timeout: 1).type
  end

  def test_unsubscribe_updates_tracked_subscriptions
    @subscription.subscribe("a", "b").unsubscribe("a")
    3.times { @subscription.next_message(timeout: 1) }

    assert_equal({ channels: ["b"], patterns: [], shards: [] }, @subscription.subscriptions)
    assert @subscription.subscribed?

    @subscription.unsubscribe
    refute @subscription.subscribed?
  end

  def test_resubscribes_after_a_connection_loss
    @subscription.subscribe("events").psubscribe("alerts.*")
    2.times { @subscription.next_message(timeout: 1) }

    @server.disconnect_all
    confirmations = 2.times.map { @subscription.next_message(timeout: 1) }

    assert_equal %i[subscribe psubscribe], confirmations.map(&:type)
    assert_equal 2, @server.connection_count
    wait_until { @server.publish("events", "again") == 1 }
    assert_equal "again", @subscription.next_message(timeout: 1).payload
  end

  def test_raises_when_reconnect_attempts_are_exhausted
    subscription = SolidRedis.config(port: @server.port, timeout: 0.5, reconnect_attempts: 0).new_subscription
    subscription.subscribe("events")
    subscription.next_message(timeout: 1)
    @server.disconnect_all

    assert_raises(SolidRedis::ConnectionError) { subscription.next_message(timeout: 1) }
  ensure
    subscription&.close
  end

  def test_regular_commands_are_rejected
    assert_raises(SolidRedis::Error) { @subscription.call("GET", "key") }
    assert_raises(SolidRedis::Error) { @subscription.pipelined { |p| p.call("PING") } }
  end

  def test_each_message_yields_nil_on_timeout
    @subscription.subscribe("events")
    seen = []
    @subscription.each_message(timeout: 0.05) do |message|
      seen << message&.type
      break if seen.length == 2
    end

    assert_equal [:subscribe, nil], seen
  end

  def test_dedicated_listener_ractor_fans_out_to_other_ractors
    port = ractor_port
    listener = Ractor.new(@config, port) do |config, port|
      subscription = config.new_subscription
      subscription.subscribe("events")
      subscription.next_message(timeout: 2)
      RactorCompat.emit(port, :ready)
      message = subscription.next_message(timeout: 2)
      RactorCompat.emit(port, [message.channel, message.payload].freeze)
      subscription.close
      :done
    end

    assert_equal :ready, ractor_receive(listener, port)
    wait_until { @server.publish("events", "from-main") == 1 }
    assert_equal ["events", "from-main"], ractor_receive(listener, port)
    assert_equal :done, ractor_result(listener)
  end

  private

  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      raise "condition not met within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.01
    end
  end
end
