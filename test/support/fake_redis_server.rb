# frozen_string_literal: true

require "socket"

class FakeRedisServer
  attr_reader :port

  def initialize(&responder)
    @responder = responder
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.local_address.ip_port
    @commands = []
    @clients = []
    @mutex = Mutex.new
    @running = true
    @accept_thread = Thread.new { accept_connections }
  end

  def commands
    @mutex.synchronize { @commands.dup }
  end

  def connection_count
    @mutex.synchronize { @clients.length }
  end

  def stop
    @running = false
    @server.close
    clients = @mutex.synchronize { @clients.dup }
    clients.each { |client| client.close rescue nil }
    @accept_thread.join
  end

  private

  def accept_connections
    while @running
      client = @server.accept
      @mutex.synchronize { @clients << client }
      Thread.new(client) { |socket| serve(socket) }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(socket)
    while (command = read_command(socket))
      @mutex.synchronize { @commands << command }
      socket.write(encode(@responder.call(command)))
    end
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close rescue nil
  end

  def read_command(socket)
    header = socket.gets("\r\n")
    return unless header
    raise "Expected RESP array, got #{header.inspect}" unless header.start_with?("*")

    Array.new(Integer(header[1..])) do
      length = Integer(socket.gets("\r\n")[1..])
      value = socket.read(length)
      socket.read(2)
      value
    end
  end

  def encode(value)
    case value
    when Simple
      "+#{value.value}\r\n"
    when Error
      "-#{value.value}\r\n"
    when String
      "$#{value.bytesize}\r\n#{value}\r\n"
    when Integer
      ":#{value}\r\n"
    when Array
      "*#{value.length}\r\n#{value.map { |element| encode(element) }.join}"
    when Hash
      encode(value.to_a.flatten)
    when NilClass
      "$-1\r\n"
    else
      raise "Cannot encode #{value.inspect}"
    end
  end

  Simple = Struct.new(:value)
  Error = Struct.new(:value)
end
