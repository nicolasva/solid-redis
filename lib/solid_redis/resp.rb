# frozen_string_literal: true

module SolidRedis
  module RESP
    CRLF = "\r\n"

    module_function

    def encode(command)
      length = command.sum { |argument| argument.is_a?(Array) ? argument.length : 1 }
      raise ArgumentError, "Redis command cannot be empty" if length.zero?

      command.each_with_object(+"*#{length}#{CRLF}") do |argument, buffer|
        if argument.is_a?(Array)
          argument.each { |value| append_argument(buffer, value) }
        else
          append_argument(buffer, argument)
        end
      end
    end

    def append_argument(buffer, argument)
      value = encode_argument(argument)
      buffer << "$#{value.bytesize}#{CRLF}#{value}#{CRLF}"
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
        @offset = 0
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
        return true if available_bytes.positive?
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
        when "|" then read_attribute(exception)
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

        finish_collection(Array.new(length) { read(exception: false) }, exception)
      end

      def read_collection(exception)
        length = Integer(read_line)
        finish_collection(Array.new(length) { read(exception: false) }, exception)
      end

      def read_map(exception)
        length = Integer(read_line)
        map = {}.tap do |result|
          length.times { result[read(exception: false)] = read(exception: false) }
        end
        finish_collection(map, exception)
      end

      def read_attribute(exception)
        attributes = read_map(false)
        value = read(exception: false)
        raise_nested_error(attributes) if exception
        raise_nested_error(value) if exception
        value
      end

      def finish_collection(value, exception)
        raise_nested_error(value) if exception
        value
      end

      def raise_nested_error(value)
        case value
        when CommandError
          raise value
        when Array
          value.each { |element| raise_nested_error(element) }
        when Hash
          value.each do |key, element|
            raise_nested_error(key)
            raise_nested_error(element)
          end
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
          if (index = @buffer.index(CRLF, @offset))
            value = @buffer.byteslice(@offset, index - @offset)
            @offset = index + 2
            clear_consumed_buffer
            return value
          end
          fill_buffer
        end
      end

      def read_bytes(length)
        fill_buffer while available_bytes < length
        value = @buffer.byteslice(@offset, length)
        @offset += length
        clear_consumed_buffer
        value
      end

      def fill_buffer
        compact_buffer
        wait_for = :readable
        deadline = nil
        loop do
          if @io.respond_to?(:to_io)
            chunk = @io.read_nonblock(16_384, exception: false)
          else
            chunk = @io.read(16_384)
          end

          if chunk == :wait_readable || chunk == :wait_writable
            wait_for = chunk == :wait_readable ? :readable : :writable
            deadline ||= monotonic_time + @read_timeout if @read_timeout
            remaining = deadline && deadline - monotonic_time
            if remaining && remaining <= 0
              raise TimeoutError, "Redis read timed out after #{@read_timeout}s"
            end

            readers = wait_for == :readable ? [@io] : nil
            writers = wait_for == :writable ? [@io] : nil
            unless IO.select(readers, writers, nil, remaining)
              raise TimeoutError, "Redis read timed out after #{@read_timeout}s"
            end
            next
          end
          raise EOFError if chunk.nil?

          @buffer << chunk
          return
        end
      rescue IOError, SystemCallError => error
        raise ConnectionError, error.message, cause: error
      end

      def available_bytes
        @buffer.bytesize - @offset
      end

      def clear_consumed_buffer
        return unless @offset == @buffer.bytesize

        @buffer.clear
        @offset = 0
      end

      def compact_buffer
        return if @offset.zero?

        @buffer = @buffer.byteslice(@offset..) || +""
        @offset = 0
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
