# frozen_string_literal: true

module SolidRedis
  module RESP
    CRLF = SolidRespRactor::Encoder::CRLF

    module ErrorMapper
      module_function

      def call(message, blob:)
        error_class = if message.start_with?("NOAUTH", "WRONGPASS")
          AuthenticationError
        else
          CommandError
        end
        error_class.new(message)
      end
    end

    CODEC = SolidRespRactor::Codec.new(error_mapper: ErrorMapper)
    Ractor.make_shareable(CODEC)

    module_function

    def encode(command)
      CODEC.encode(command)
    end

    class Reader < SolidRespRactor::Reader
      def initialize(io, read_timeout:)
        super(io, read_timeout: read_timeout, error_mapper: ErrorMapper)
      end

      def read(...)
        super
      rescue SolidRespRactor::ProtocolError => error
        raise ProtocolError, error.message, cause: error
      rescue SolidRespRactor::TimeoutError => error
        raise TimeoutError, error.message, cause: error
      rescue SolidRespRactor::ConnectionError => error
        raise ConnectionError, error.message, cause: error
      end

      def wait_readable(...)
        super
      rescue SolidRespRactor::TimeoutError => error
        raise TimeoutError, error.message, cause: error
      rescue SolidRespRactor::ConnectionError => error
        raise ConnectionError, error.message, cause: error
      end
    end
  end
end
