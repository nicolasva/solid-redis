# frozen_string_literal: true

module SolidRedis
  class Pool
    attr_reader :size

    def initialize(config, size: 5, timeout: 1.0)
      @config = config
      @size = Integer(size)
      raise ArgumentError, "Pool size must be positive" unless @size.positive?

      @timeout = Float(timeout)
      raise ArgumentError, "Pool timeout must be positive" unless @timeout.positive?

      @available = []
      @created = 0
      @mutex = Mutex.new
      @resource = ConditionVariable.new
      @closed = false
      @owner = Ractor.current
    end

    def with
      ensure_owner!
      client = checkout
      yield client
    ensure
      checkin(client) if client
    end
    alias_method :then, :with

    def call(*command)
      with { |client| client.call(*command) }
    end

    def call_v(command)
      with { |client| client.call_v(command) }
    end

    def pipelined(exception: true, &block)
      with { |client| client.pipelined(exception: exception, &block) }
    end

    def close
      ensure_owner!
      clients = @mutex.synchronize do
        @closed = true
        @resource.broadcast
        @available.shift(@available.length)
      end
      clients.each(&:close)
      self
    end

    private

    def checkout
      deadline = monotonic_time + @timeout
      @mutex.synchronize do
        loop do
          raise ClosedError, "Redis pool is closed" if @closed
          return @available.pop unless @available.empty?

          if @created < size
            @created += 1
            return @config.new_client
          end

          remaining = deadline - monotonic_time
          unless remaining.positive?
            raise CheckoutTimeoutError, "Redis pool checkout timed out after #{@timeout}s"
          end

          @resource.wait(@mutex, remaining)
        end
      end
    end

    def checkin(client)
      @mutex.synchronize do
        if @closed
          @created -= 1
          client.close
        else
          @available << client
          @resource.signal
        end
      end
    end

    def ensure_owner!
      return if Ractor.current == @owner

      raise Ractor::IsolationError, "SolidRedis::Pool cannot cross Ractor boundaries"
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
