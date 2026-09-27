# frozen_string_literal: true

require "test_helper"

class CommandKeyTest < Minitest::Test
  def test_memory_usage_routes_by_key
    assert_equal "cache:key", SolidRedis::Cluster::CommandKey.for(["MEMORY", "USAGE", "cache:key"])
    assert_equal "cache:key", SolidRedis::Cluster::CommandKey.for(["memory", "usage", "cache:key"])
  end

  def test_other_memory_subcommands_are_keyless
    assert_nil SolidRedis::Cluster::CommandKey.for(["MEMORY", "STATS"])
    assert_nil SolidRedis::Cluster::CommandKey.for(["MEMORY", "DOCTOR"])
    assert_nil SolidRedis::Cluster::CommandKey.for(["MEMORY", "PURGE"])
  end
end
