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
    @subscriptions = {}
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

  # Pushes a Pub/Sub message to every socket subscribed to +channel+, either
  # directly or through a matching glob pattern.
  def publish(channel, payload)
    targets = @mutex.synchronize do
      @subscriptions.filter_map do |socket, subs|
        if subs[:channels].include?(channel)
          [socket, encode(["message", channel, payload])]
        elsif (pattern = subs[:patterns].find { |glob| File.fnmatch(glob, channel) })
          [socket, encode(["pmessage", pattern, channel, payload])]
        end
      end
    end
    targets.each { |socket, frame| socket.write(frame) rescue nil }
    targets.length
  end

  def disconnect_all
    clients = @mutex.synchronize { @clients.dup }
    clients.each { |client| client.close rescue nil }
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
      response = pubsub(socket, command)
      encoded = !response.nil?
      response ||= @responder.call(command)
      if response.is_a?(Close)
        socket.write(response.value) if response.value
        break
      end

      socket.write(encoded ? response : encode(response))
    end
  rescue IOError, SystemCallError
    nil
  ensure
    @mutex.synchronize { @subscriptions.delete(socket) }
    socket.close rescue nil
  end

  # Minimal Pub/Sub state machine; returns nil for non Pub/Sub commands.
  def pubsub(socket, command)
    name, *args = command
    kind = case name
    when "SUBSCRIBE", "UNSUBSCRIBE" then :channels
    when "PSUBSCRIBE", "PUNSUBSCRIBE" then :patterns
    end
    subs = @mutex.synchronize { @subscriptions[socket] }

    if kind
      subs ||= @mutex.synchronize { @subscriptions[socket] = { channels: [], patterns: [] } }
      subscribing = name.start_with?("SUBSCRIBE", "PSUBSCRIBE")
      args = subs[kind].dup if args.empty? && !subscribing
      args.map do |arg|
        subscribing ? (subs[kind] << arg unless subs[kind].include?(arg)) : subs[kind].delete(arg)
        encode([name.downcase, arg, subs.values.sum(&:length)])
      end.join
    elsif subs && name == "PING"
      encode(["pong", args.first || ""])
    end
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
    when Raw
      value.value
    when NilClass
      "$-1\r\n"
    else
      raise "Cannot encode #{value.inspect}"
    end
  end

  Simple = Struct.new(:value)
  Error = Struct.new(:value)
  Raw = Struct.new(:value)
  Close = Struct.new(:value)
end
