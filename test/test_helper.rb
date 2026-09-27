# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "solid_redis"

module RactorCompat
  # Ractor#take was removed in Ruby 4.0 in favor of Ractor#value.
  def ractor_result(ractor)
    ractor.respond_to?(:value) ? ractor.value : ractor.take
  end
end

Minitest::Test.include RactorCompat
