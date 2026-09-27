# frozen_string_literal: true

require "test_helper"
require_relative "support/fake_redis_server"

class ThreadStressTest < Minitest::Test
  THREADS = 8
  DIRECT_CALLS = 50
  PIPELINES = 20
  PIPELINE_SIZE = 10

  def setup
    @server = FakeRedisServer.new do |command|
      command.first == "ECHO" ? command[1] : FakeRedisServer::Error.new("ERR unsupported")
    end
    @pool = SolidRedis.config(port: @server.port, timeout: 1.0).new_pool(size: 4, timeout: 2.0)
  end

  def teardown
    @pool.close
    @server.stop
  end

  def test_concurrent_direct_calls_and_pipelines
    ready = Queue.new
    start = Queue.new
    workers = THREADS.times.map do |thread_index|
      Thread.new do
        ready << true
        start.pop

        direct = DIRECT_CALLS.times.count do |iteration|
          token = "direct:#{thread_index}:#{iteration}"
          @pool.call("ECHO", token) == token
        end
        pipelined = PIPELINES.times.sum do |pipeline_index|
          expected = PIPELINE_SIZE.times.map { |index| "pipeline:#{thread_index}:#{pipeline_index}:#{index}" }
          actual = @pool.pipelined do |pipeline|
            expected.each { |token| pipeline.call("ECHO", token) }
          end
          actual == expected ? actual.length : 0
        end
        [direct, pipelined]
      end
    end
    THREADS.times { ready.pop }
    THREADS.times { start << true }

    assert_equal [[DIRECT_CALLS, PIPELINES * PIPELINE_SIZE]] * THREADS, workers.map(&:value)
    assert_operator @server.connection_count, :<=, @pool.size
  end
end
