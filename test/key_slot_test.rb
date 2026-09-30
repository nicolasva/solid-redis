# frozen_string_literal: true

require "test_helper"

class KeySlotTest < Minitest::Test
  def test_known_cluster_slots
    assert_equal 12_182, SolidRedis::Cluster::KeySlot.for("foo")
    assert_equal 5_061, SolidRedis::Cluster::KeySlot.for("bar")
  end

  def test_hash_tags_route_to_the_same_slot
    assert_equal(
      SolidRedis::Cluster::KeySlot.for("user1000"),
      SolidRedis::Cluster::KeySlot.for("{user1000}.following"),
    )
    assert_equal(
      SolidRedis::Cluster::KeySlot.for("user1000"),
      SolidRedis::Cluster::KeySlot.for("{user1000}.followers"),
    )
  end

  def test_empty_or_unclosed_hash_tags_use_the_complete_key
    refute_equal(
      SolidRedis::Cluster::KeySlot.for("foo"),
      SolidRedis::Cluster::KeySlot.for("foo{}"),
    )
    assert_equal(
      SolidRedis::Cluster::KeySlot.crc16("foo{bar") %
        SolidRedis::Cluster::KeySlot::SLOTS,
      SolidRedis::Cluster::KeySlot.for("foo{bar"),
    )
  end
end
