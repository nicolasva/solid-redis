# frozen_string_literal: true

module SolidRedis
  class Error < StandardError; end
  class ConnectionError < Error; end
  class TimeoutError < ConnectionError; end
  class ProtocolError < Error; end
  class CommandError < Error; end
  class AuthenticationError < CommandError; end
  class FailoverError < ConnectionError; end
  class CheckoutTimeoutError < TimeoutError; end
  class ClosedError < Error; end
end
