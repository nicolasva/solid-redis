# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_redis_server"

class IntegrationDependenciesTest < Minitest::Test
  module Events
    def self.connected(_url)
      raise "connected callback invoked"
    end
  end

  def test_sentinel_resolution_uses_base_service
    assert_operator SolidRedis::Sentinel::ResolveService, :<, Service::Base
  end

  def test_shareable_callback_collection_receives_client_events
    callbacks = CallbackCollection.new do |collection|
      collection.register(:connected, Events)
    end
    config = SolidRedis.config(port: 1, callbacks: callbacks, connect_timeout: 0.01)

    assert Ractor.shareable?(config)

    server = FakeRedisServer.new { FakeRedisServer::Simple.new("PONG") }
    config = SolidRedis.config(port: server.port, callbacks: callbacks)
    error = assert_raises(RuntimeError) { config.new_client.call("PING") }
    assert_equal "connected callback invoked", error.message
  ensure
    server&.stop
  end

  def test_block_callbacks_are_rejected_as_non_shareable
    callbacks = CallbackCollection.new { |collection| collection.connected {} }

    error = assert_raises(ArgumentError) { SolidRedis.config(callbacks: callbacks) }
    assert_match(/callbacks must be Ractor-shareable/, error.message)
  end
end
