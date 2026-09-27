# frozen_string_literal: true

require "stringio"
require "socket"
require "test_helper"

class RESPTest < Minitest::Test
  def test_encodes_commands
    assert_equal "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", SolidRedis::RESP.encode(["GET", "key"])
  end

  def test_encodes_nested_command_arguments_without_mutating_them
    command = ["MSET", ["first", 1], ["second", 2]]

    assert_equal(
      "*5\r\n$4\r\nMSET\r\n$5\r\nfirst\r\n$1\r\n1\r\n$6\r\nsecond\r\n$1\r\n2\r\n",
      SolidRedis::RESP.encode(command),
    )
    assert_equal ["MSET", ["first", 1], ["second", 2]], command
  end

  def test_decodes_resp2_and_resp3_values
    payload = "*5\r\n+OK\r\n:42\r\n$3\r\nfoo\r\n_\r\n#t\r\n"
    reader = SolidRedis::RESP::Reader.new(StringIO.new(payload), read_timeout: 0.1)

    assert_equal ["OK", 42, "foo", nil, true], reader.read
  end

  def test_returns_pipeline_errors_when_requested
    reader = SolidRedis::RESP::Reader.new(StringIO.new("-ERR broken\r\n"), read_timeout: 0.1)

    assert_instance_of SolidRedis::CommandError, reader.read(exception: false)
  end

  def test_consumes_a_whole_array_before_raising_a_nested_error
    io = StringIO.new("*3\r\n+before\r\n-ERR broken\r\n+after\r\n+next\r\n")
    reader = SolidRedis::RESP::Reader.new(io, read_timeout: 0.1)

    error = assert_raises(SolidRedis::CommandError) { reader.read }

    assert_equal "ERR broken", error.message
    assert_equal "next", reader.read
  end

  def test_waits_for_writable_when_nonblocking_read_requires_it
    io = WaitWritableIO.new("+OK\r\n")
    reader = SolidRedis::RESP::Reader.new(io, read_timeout: 0.1)

    assert_equal "OK", reader.read
  ensure
    io&.close
  end

  def test_reads_fragmented_responses_with_unconsumed_buffer_data
    io = FragmentedIO.new(["+fi", "rst\r\n+sec", "ond\r\n"])
    reader = SolidRedis::RESP::Reader.new(io, read_timeout: 0.1)

    assert_equal "first", reader.read
    assert_equal "second", reader.read
  end

  class WaitWritableIO
    def initialize(payload)
      @reader, @writer = Socket.pair(:UNIX, :STREAM)
      @writer.write(".")
      @payload = payload
      @attempts = 0
    end

    def to_io
      @reader
    end

    def read_nonblock(_length, exception:)
      raise ArgumentError, "expected exception: false" unless exception == false

      @attempts += 1
      @attempts == 1 ? :wait_writable : @payload
    end

    def close
      @reader.close
      @writer.close
    end
  end

  class FragmentedIO
    def initialize(chunks)
      @chunks = chunks
    end

    def read(_length)
      @chunks.shift
    end
  end
end
