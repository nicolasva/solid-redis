# frozen_string_literal: true

module SolidRedis
  module RESP
    CRLF = "\r\n"

    module_function

    def encode(command)
      command = command.flatten(1)
      raise ArgumentError, "Redis command cannot be empty" if command.empty?

      command.each_with_object(+"*#{command.length}#{CRLF}") do |argument, buffer|
        value = encode_argument(argument)
        buffer << "$#{value.bytesize}#{CRLF}#{value}#{CRLF}"
      end
    end

    def encode_argument(value)
      case value
      when String then value
      when Symbol, Integer, Float then value.to_s
      when true then "1"
      when false then "0"
      when nil then ""
      else value.to_s
      end
    end

    class Reader
      def initialize(io, read_timeout:)
        @io = io
        @read_timeout = read_timeout
        @buffer = +""
      end

      # Temporarily overrides the read timeout. +nil+ waits forever, which is
      # what blocking commands such as BLPOP with a 0 timeout require.
      def with_timeout(timeout)
        previous = @read_timeout
        @read_timeout = timeout
        yield
      ensure
        @read_timeout = previous
      end

      # Waits until at least one byte is available without consuming it.
      # Returns +false+ on timeout. Unlike a timed-out +read+, this never
      # leaves a partially consumed frame behind, so it is the safe way to
      # poll for the next Pub/Sub message.
      def wait_readable(timeout)
        return true unless @buffer.empty?
        return true unless @io.respond_to?(:to_io)

        !IO.select([@io], nil, nil, timeout).nil?
      rescue IOError, SystemCallError => error
        raise ConnectionError, error.message, cause: error
      end

      def read(exception: true)
        case (type = read_bytes(1))
        when "+" then read_line
        when "-" then error_response(read_line, exception)
        when ":" then Integer(read_line)
        when "$" then read_bulk
        when "*" then read_array(exception)
        when "_" then read_line && nil
        when "#" then read_line == "t"
        when "," then Float(read_line)
        when "(" then Integer(read_line)
        when "%" then read_map(exception)
        when "~", ">" then read_collection(exception)
        when "=" then read_verbatim
        when "!" then error_response(read_sized_string, exception)
        when "|" then read_map(exception) && read(exception: exception)
        else raise ProtocolError, "Unknown RESP type byte: #{type.inspect}"
        end
      rescue EOFError
        raise ConnectionError, "Redis closed the connection"
      rescue ArgumentError => error
        raise ProtocolError, "Invalid Redis response: #{error.message}", cause: error
      end

      private

      def read_bulk
        length = Integer(read_line)
        return if length == -1

        read_sized_value(length)
      end

      def read_array(exception)
        length = Integer(read_line)
        return if length == -1

        Array.new(length) { read(exception: exception) }
      end

      def read_collection(exception)
        length = Integer(read_line)
        Array.new(length) { read(exception: exception) }
      end

      def read_map(exception)
        length = Integer(read_line)
        {}.tap do |map|
          length.times { map[read(exception: exception)] = read(exception: exception) }
        end
      end

      def read_verbatim
        read_sized_string.byteslice(4..)
      end

      def read_sized_string
        read_sized_value(Integer(read_line))
      end

      def read_sized_value(length)
        value = read_bytes(length)
        actual = read_bytes(2)
        raise ProtocolError, "Expected CRLF, got #{actual.inspect}" unless actual == CRLF

        value
      end

      def read_line
        loop do
          if (index = @buffer.index(CRLF))
            return @buffer.slice!(0, index + 2).byteslice(0, index)
          end
          fill_buffer
        end
      end

      def read_bytes(length)
        fill_buffer while @buffer.bytesize < length
        @buffer.slice!(0, length)
      end

      def fill_buffer
        loop do
          if @io.respond_to?(:to_io)
            unless IO.select([@io], nil, nil, @read_timeout)
              raise TimeoutError, "Redis read timed out after #{@read_timeout}s"
            end

            chunk = @io.read_nonblock(16_384, exception: false)
          else
            chunk = @io.read(16_384)
          end

          next if chunk == :wait_readable
          raise EOFError if chunk.nil?

          @buffer << chunk
          return
        end
      rescue IOError, SystemCallError => error
        raise ConnectionError, error.message, cause: error
      end

      def error_response(message, exception)
        error = if message.start_with?("NOAUTH", "WRONGPASS")
          AuthenticationError.new(message)
        else
          CommandError.new(message)
        end
        raise error if exception

        error
      end
    end
  end
end
