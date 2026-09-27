# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "solid_redis"

module RactorCompat
  # Ractor#take was removed in Ruby 4.0 in favor of Ractor#value.
  def ractor_result(ractor)
    ractor.respond_to?(:value) ? ractor.value : ractor.take
  end

  # Ruby 4.0 replaced Ractor.yield/Ractor#take with Ractor::Port. Returns a
  # shareable port on 4.0 and nil on 3.x; pair it with +ractor_emit+ inside
  # the Ractor and +ractor_receive+ outside.
  def ractor_port
    defined?(Ractor::Port) ? Ractor::Port.new : nil
  end

  def ractor_receive(ractor, port)
    port ? port.receive : ractor.take
  end

  def self.emit(port, value)
    port ? port << value : Ractor.yield(value)
  end
end

Minitest::Test.include RactorCompat
