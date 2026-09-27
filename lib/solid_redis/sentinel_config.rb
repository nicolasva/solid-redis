# frozen_string_literal: true

module SolidRedis
  class SentinelConfig
    LOCAL_STATE_KEY = :solid_redis_sentinel_states
    DEFAULT_SENTINEL_PORT = 26_379

    attr_reader :name, :role, :reconnect_attempts, :redis_client_options,
      :sentinel_client_options, :sentinel_endpoints

    def initialize(
      name:,
      sentinels:,
      role: :master,
      sentinel_username: nil,
      sentinel_password: nil,
      sentinel_ssl: false,
      sentinel_ssl_params: nil,
      **redis_options
    )
      @name = String(name).dup.freeze
      @role = normalize_role(role)
      endpoints = sentinels.map { |endpoint| normalize_endpoint(endpoint) }
      @sentinel_endpoints = Shareable.copy(endpoints, label: "sentinels")
      raise ArgumentError, "At least one Sentinel endpoint is required" if @sentinel_endpoints.empty?

      @reconnect_attempts = Integer(redis_options.fetch(:reconnect_attempts, 2))
      raise ArgumentError, "reconnect_attempts must not be negative" if @reconnect_attempts.negative?

      @redis_client_options = Shareable.copy(redis_options, label: "Redis options")
      @sentinel_client_options = Shareable.copy(
        sentinel_options(
          redis_options,
          username: sentinel_username,
          password: sentinel_password,
          ssl: sentinel_ssl,
          ssl_params: sentinel_ssl_params,
        ),
        label: "Sentinel options",
      )
      Ractor.make_shareable(self)
    end

    def sentinel?
      true
    end

    def resolved?
      state.resolved?
    end

    def resolve
      state.resolve
    end

    def reset
      state.reset
      self
    end

    def host
      resolve.host
    end

    def port
      resolve.port
    end

    def path
      nil
    end

    def server_key
      resolve.server_key
    end

    def server_url
      resolve.server_url
    end

    def sentinels
      state.sentinel_endpoints
    end

    def new_client(**options)
      Client.new(self, **options)
    end

    def new_pool(**options)
      Pool.new(self, **options)
    end

    def notify(event, *arguments)
      callbacks = redis_client_options[:callbacks]
      return unless callbacks&.respond_to?(event)

      callbacks.respond_with(event, *arguments)
    end

    def inspect
      "#<#{self.class.name} name=#{name.inspect} role=#{role.inspect} sentinels=#{sentinel_endpoints.length}>"
    end

    private

    def state
      registry = Ractor.current[LOCAL_STATE_KEY]
      unless registry
        registry = { mutex: Mutex.new, states: {} }
        Ractor.current[LOCAL_STATE_KEY] = registry
      end

      registry[:mutex].synchronize do
        registry[:states][self] ||= SentinelState.new(self)
      end
    end

    def normalize_role(role)
      role = role.to_sym
      role = :replica if role == :slave
      return role if %i[master replica].include?(role)

      raise ArgumentError, "role must be :master or :replica"
    end

    def normalize_endpoint(endpoint)
      return endpoint.transform_keys(&:to_sym) unless endpoint.is_a?(String)

      uri = URI.parse(endpoint)
      unless %w[redis rediss].include?(uri.scheme)
        raise ArgumentError, "Unsupported Sentinel URL scheme: #{uri.scheme.inspect}"
      end

      {
        host: uri.host || "127.0.0.1",
        port: uri.port || DEFAULT_SENTINEL_PORT,
        username: decode(uri.user),
        password: decode(uri.password),
        ssl: uri.scheme == "rediss",
      }.compact
    rescue URI::InvalidURIError => error
      raise ArgumentError, "Invalid Sentinel URL: #{error.message}", cause: error
    end

    def sentinel_options(redis_options, **credentials)
      timeout = redis_options.fetch(:timeout, Config::DEFAULT_TIMEOUT)
      {
        **credentials,
        connect_timeout: redis_options.fetch(:connect_timeout, timeout),
        read_timeout: redis_options.fetch(:read_timeout, timeout),
        write_timeout: redis_options.fetch(:write_timeout, timeout),
        reconnect_attempts: 0,
      }.compact
    end

    def decode(value)
      URI.decode_www_form_component(value) if value
    end
  end
end
