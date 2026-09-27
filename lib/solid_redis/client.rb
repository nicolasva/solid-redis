# frozen_string_literal: true

require "openssl"
require "socket"

module SolidRedis
  class Client
    attr_reader :config

    def initialize(config, name: nil)
      @config = config
      @name = name&.to_s
      @socket = nil
      @reader = nil
      @target = nil
    end

    def call(*command)
      call_v(command)
    end

    def call_v(command)
      with_reconnect do
        write(RESP.encode(command))
        @reader.read
      end
    end

    # Runs a blocking command such as BLPOP, BRPOP, BZPOPMIN or XREAD BLOCK.
    #
    # +timeout+ is the number of seconds Redis was asked to block for; the
    # socket read timeout becomes +timeout+ plus the configured read timeout.
    # Pass +nil+ or +0+ when Redis blocks indefinitely: the read then waits
    # forever. The command is never retried after a connection error because
    # the element may already have been consumed.
    def blocking_call(timeout, *command)
      blocking_call_v(timeout, command)
    end

    def blocking_call_v(timeout, command)
      with_reconnect { connect unless connected? }

      read_timeout = timeout && timeout.positive? ? timeout + @target.read_timeout : nil
      begin
        write(RESP.encode(command))
        @reader.with_timeout(read_timeout) { @reader.read }
      rescue ProtocolError, ConnectionError, IO::WaitReadable, IO::WaitWritable, SystemCallError => error
        handle_connection_failure(error)
        raise error if error.is_a?(Error)

        raise ConnectionError, error.message, cause: error
      end
    end

    def pipelined(exception: true)
      pipeline = Pipeline.new
      yield pipeline
      return [] if pipeline.commands.empty?

      with_reconnect do
        write(pipeline.commands.map { |command| RESP.encode(command) }.join)
        results = pipeline.commands.map { @reader.read(exception: false) }
        if exception && (error = results.find { |result| result.is_a?(CommandError) })
          raise error
        end

        results
      end
    end

    def connected?
      @socket && !@socket.closed?
    end

    def close
      socket = @socket
      target = @target
      @socket = @reader = @target = nil
      socket&.close
      config.notify(:disconnected, target.server_url) if socket && target
      self
    rescue IOError
      self
    end

    def server_url
      config.server_url
    end

    private

    def with_reconnect
      attempts = 0
      begin
        connect unless connected?
        yield
      rescue ProtocolError => error
        handle_connection_failure(error)
        raise
      rescue ConnectionError, IO::WaitReadable, IO::WaitWritable, SystemCallError => error
        handle_connection_failure(error)
        if attempts < config.reconnect_attempts
          attempts += 1
          retry
        end
        raise error if error.is_a?(Error)

        raise ConnectionError, error.message, cause: error
      end
    end

    def handle_connection_failure(error)
      close
      config.reset if config.sentinel?
      config.notify(:connection_error, error.class.name, error.message)
    end

    def connect
      @target = config.sentinel? ? config.resolve : config
      @socket = open_socket(@target)
      @reader = RESP::Reader.new(@socket, read_timeout: @target.read_timeout)
      authenticate
      raw_call(["SELECT", @target.db]) unless @target.db.zero?
      raw_call(["CLIENT", "SETNAME", @name]) if @name
      verify_role if config.sentinel?
      config.notify(:connected, @target.server_url)
      self
    rescue StandardError
      close
      raise
    end

    def open_socket(target)
      socket = if target.path
        UNIXSocket.new(target.path)
      else
        Socket.tcp(target.host, target.port, connect_timeout: target.connect_timeout)
      end
      return socket unless target.ssl?

      context = OpenSSL::SSL::SSLContext.new
      apply_ssl_params(context, target.ssl_params || {})
      ssl_socket = OpenSSL::SSL::SSLSocket.new(socket, context)
      ssl_socket.hostname = target.host if ssl_socket.respond_to?(:hostname=)
      ssl_socket.sync_close = true
      ssl_connect(ssl_socket, target.connect_timeout)
      ssl_socket
    rescue TimeoutError
      socket&.close
      raise
    rescue IOError, SystemCallError, SocketError, OpenSSL::SSL::SSLError => error
      socket&.close
      raise ConnectionError, error.message, cause: error
    rescue ArgumentError
      socket&.close
      raise
    end

    def ssl_connect(socket, timeout)
      deadline = monotonic_time + timeout
      loop do
        result = socket.connect_nonblock(exception: false)
        return if result == socket

        remaining = deadline - monotonic_time
        raise TimeoutError, "TLS handshake timed out after #{timeout}s" unless remaining.positive?

        readers = result == :wait_readable ? [socket] : nil
        writers = result == :wait_writable ? [socket] : nil
        IO.select(readers, writers, nil, remaining)
      end
    end

    def apply_ssl_params(context, params)
      params.each do |name, value|
        writer = :"#{name}="
        raise ArgumentError, "Unknown SSL context option: #{name.inspect}" unless context.respond_to?(writer)

        context.public_send(writer, value)
      end
    end

    def authenticate
      return unless @target.password

      command = @target.username ? ["AUTH", @target.username, @target.password] : ["AUTH", @target.password]
      raw_call(command)
    end

    def verify_role
      actual = raw_call(["ROLE"]).first
      expected = config.role == :master ? "master" : "slave"
      return if actual == expected

      raise FailoverError, "Expected Redis role #{expected.inspect}, got #{actual.inspect}"
    end

    def raw_call(command)
      write(RESP.encode(command))
      @reader.read
    end

    def write(payload)
      offset = 0
      while offset < payload.bytesize
        unless IO.select(nil, [@socket], nil, @target.write_timeout)
          raise TimeoutError, "Redis write timed out after #{@target.write_timeout}s"
        end

        written = @socket.write_nonblock(payload.byteslice(offset..), exception: false)
        next if written == :wait_writable

        offset += written
      end
    rescue IOError, SystemCallError => error
      raise ConnectionError, error.message, cause: error
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    class Pipeline
      attr_reader :commands

      def initialize
        @commands = []
      end

      def call(*command)
        @commands << command
        nil
      end

      def call_v(command)
        @commands << command
        nil
      end
    end
  end
end
