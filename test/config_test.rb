# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  def test_is_deeply_immutable_and_shareable
    ssl_params = { verify_mode: 0 }
    config = SolidRedis.config(host: +"localhost", ssl_params: ssl_params)

    assert config.frozen?
    assert Ractor.shareable?(config)
    assert config.host.frozen?
    assert config.ssl_params.frozen?
    refute ssl_params.frozen?
  end

  def test_parses_redis_url_without_exposing_credentials
    config = SolidRedis.config(url: "rediss://alice:s%40cret@example.com:6380/4")

    assert_equal "example.com", config.host
    assert_equal 6380, config.port
    assert_equal "alice", config.username
    assert_equal "s@cret", config.password
    assert_equal 4, config.db
    assert config.ssl?
    refute_includes config.inspect, "s@cret"
  end

  def test_explicit_database_overrides_url_database
    assert_equal 5, SolidRedis.config(url: "redis://example.com", db: 5).db
    assert_equal 5, SolidRedis.config(url: "redis://example.com/4", db: 5).db
    assert_equal 5, SolidRedis.config(url: "redis://example.com?db=4", db: 5).db
    assert_equal 5, SolidRedis.config(url: "unix:///var/run/redis.sock", db: 5).db
  end

  def test_url_database_is_used_when_database_is_not_explicit
    assert_equal 0, SolidRedis.config(url: "redis://example.com").db
    assert_equal 4, SolidRedis.config(url: "redis://example.com/4").db
    assert_equal 4, SolidRedis.config(url: "redis://example.com?db=4").db
    assert_equal 4, SolidRedis.config(url: "unix:///var/run/redis.sock?db=4").db
  end

  def test_rejects_non_shareable_configuration
    error = assert_raises(ArgumentError) do
      SolidRedis.config(ssl_params: { callback: proc {} })
    end

    assert_match(/Ractor-shareable/, error.message)
  end
end
