# frozen_string_literal: true

module SolidRedis
  # A dedicated Pub/Sub connection.
  #
  # Once SUBSCRIBE has been sent, a Redis connection stops answering regular
  # commands and turns into a stream of push messages. A Subscription therefore
  # owns its own socket, is never taken from a pool, and belongs to the Ractor
  # that created it. Channel and pattern lists are tracked locally so that the
  # connection can be re-established and re-subscribed after a network error.
  class Subscription < Client
    Message = Struct.new(:type, :channel, :pattern, :payload) do
      def message?
        %i[message pmessage smessage].include?(type)
      end
    end

    SUBSCRIBE_COMMANDS = Ractor.make_shareable({
      channels: %w[SUBSCRIBE UNSUBSCRIBE],
      patterns: %w[PSUBSCRIBE PUNSUBSCRIBE],
      shards: %w[SSUBSCRIBE SUNSUBSCRIBE],
    })

    def initialize(config, name: nil)
      super
      @channels = []
      @patterns = []
      @shards = []
    end

    def subscribe(*channels)
      change(:channels, 0, channels)
    end

    def psubscribe(*patterns)
      change(:patterns, 0, patterns)
    end

    def ssubscribe(*channels)
      change(:shards, 0, channels)
    end

    def unsubscribe(*channels)
      change(:channels, 1, channels)
    end

    def punsubscribe(*patterns)
      change(:patterns, 1, patterns)
    end

    def sunsubscribe(*channels)
      change(:shards, 1, channels)
    end

    def ping(payload = nil)
      transmit { payload ? ["PING", payload] : ["PING"] }
      self
    end

    def subscriptions
      { channels: @channels.dup, patterns: @patterns.dup, shards: @shards.dup }
    end

    def subscribed?
      !(@channels.empty? && @patterns.empty? && @shards.empty?)
    end

    # Returns the next Message, or +nil+ when +timeout+ seconds elapse without
    # one. A +nil+ timeout waits forever. Connection errors trigger a reconnect
    # and a re-subscription according to +reconnect_attempts+.
    def next_message(timeout: nil)
      attempts = 0
      loop do
        ensure_connected
        return unless @reader.wait_readable(timeout)

        return decode(@reader.read)
      rescue ConnectionError, IO::WaitReadable, IO::WaitWritable, SystemCallError => error
        handle_error(error)
        raise error if attempts >= config.reconnect_attempts

        attempts += 1
      end
    end

    # Yields every incoming Message. When +timeout+ is given, yields +nil+
    # each time it elapses so the caller can check a stop condition.
    def each_message(timeout: nil)
      return enum_for(__method__, timeout: timeout) unless block_given?

      loop { yield next_message(timeout: timeout) }
    end

    def call(*)
      raise Error, "Regular commands are not available on a Pub/Sub connection"
    end
    alias_method :call_v, :call
    alias_method :pipelined, :call
    alias_method :blocking_call, :call
    alias_method :blocking_call_v, :call

    private

    # The tracked list is updated only once a connection exists, so a fresh
    # connection re-subscribes to the previous list and the new command is
    # then sent exactly once.
    def change(kind, direction, names)
      names = names.flatten.map(&:to_s)
      transmit do
        list = instance_variable_get(:"@#{kind}")
        if direction.zero?
          names.each { |name| list << name unless list.include?(name) }
        else
          names.empty? ? list.clear : list.delete_if { |name| names.include?(name) }
        end
        [SUBSCRIBE_COMMANDS[kind][direction], *names]
      end
      self
    end

    def transmit
      attempts = 0
      loop do
        ensure_connected
        return write(RESP.encode(yield))
      rescue ConnectionError, IO::WaitReadable, IO::WaitWritable, SystemCallError => error
        handle_error(error)
        raise error if attempts >= config.reconnect_attempts

        attempts += 1
      end
    end

    def ensure_connected
      return if connected?

      connect
      resubscribe
    end

    # Re-issues the tracked subscriptions on a fresh connection. Confirmation
    # events flow back to the caller as :subscribe/:psubscribe/:ssubscribe.
    def resubscribe
      write(RESP.encode(["SUBSCRIBE", *@channels])) unless @channels.empty?
      write(RESP.encode(["PSUBSCRIBE", *@patterns])) unless @patterns.empty?
      write(RESP.encode(["SSUBSCRIBE", *@shards])) unless @shards.empty?
    end

    def handle_error(error)
      close
      config.reset if config.sentinel?
      config.notify(:connection_error, error.class.name, error.message)
      raise ConnectionError, error.message, cause: error unless error.is_a?(Error)
    end

    def decode(reply)
      unless reply.is_a?(Array) && reply.first.is_a?(String)
        raise ProtocolError, "Unexpected Pub/Sub reply: #{reply.inspect}"
      end

      type = reply[0].to_sym
      case type
      when :message, :smessage
        Message.new(type, reply[1], nil, reply[2])
      when :pmessage
        Message.new(type, reply[2], reply[1], reply[3])
      when :pong
        Message.new(type, nil, nil, reply[1])
      when :psubscribe, :punsubscribe
        Message.new(type, nil, reply[1], reply[2])
      else
        Message.new(type, reply[1], nil, reply[2])
      end.freeze
    end
  end
end
