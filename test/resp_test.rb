# frozen_string_literal: true

require "stringio"
require "test_helper"

class RESPTest < Minitest::Test
  def test_encodes_commands
    assert_equal "*2\r\n$3\r\nGET\r\n$3\r\nkey\r\n", SolidRedis::RESP.encode(["GET", "key"])
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
end
