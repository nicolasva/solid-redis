# frozen_string_literal: true

module SolidRedis
  # Immutable, Ractor-shareable description of a Redis Cluster: seed nodes and
  # per-node client options. Slot tables, node clients and sockets live in a
  # per-Ractor ClusterState, exactly like SentinelConfig/SentinelState.
  class ClusterConfig
    LOCAL_STATE_KEY = :solid_redis_cluster_states
    DEFAULT_PORT = 6379
    DEFAULT_MAX_REDIRECTIONS = 5

    attr_reader :node_endpoints, :redis_client_options, :reconnect_attempts, :max_redirections

    def initialize(nodes:, max_redirections: DEFAULT_MAX_REDIRECTIONS, **redis_options)
      endpoints = Array(nodes).map { |endpoint| normalize_endpoint(endpoint) }
      @node_endpoints = Shareable.copy(endpoints, label: "nodes")
      raise ArgumentError, "At least one cluster node is required" if @node_endpoints.empty?

      @max_redirections = Integer(max_redirections)
      raise ArgumentError, "max_redirections must not be negative" if @max_redirections.negative?

      @reconnect_attempts = Integer(redis_options.fetch(:reconnect_attempts, 1))
      raise ArgumentError, "reconnect_attempts must not be negative" if @reconnect_attempts.negative?
      raise ArgumentError, "Redis Cluster only supports database 0" if redis_options.fetch(:db, 0) != 0

      @redis_client_options = Shareable.copy(redis_options, label: "Redis options")
      Ractor.make_shareable(self)
    end

    def sentinel?
      false
    end

    def cluster?
      true
    end

    def discovered?
      state.discovered?
    end

    def nodes
      state.nodes
    end

    def reset
      state.reset
      self
    end

    def refresh
      state.refresh
      self
    end

    def new_client(**options)
      ClusterClient.new(self, **options)
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
      "#<#{self.class.name} nodes=#{node_endpoints.length}>"
    end

    # Per-Ractor runtime state, created on first use in each Ractor.
    def state
      registry = Ractor.current[LOCAL_STATE_KEY]
      unless registry
        registry = { mutex: Mutex.new, states: {} }
        Ractor.current[LOCAL_STATE_KEY] = registry
      end

      registry[:mutex].synchronize do
        registry[:states][self] ||= ClusterState.new(self)
      end
    end

    private

    def normalize_endpoint(endpoint)
      unless endpoint.is_a?(String)
        endpoint = endpoint.transform_keys(&:to_sym)
        return { host: endpoint.fetch(:host), port: Integer(endpoint.fetch(:port, DEFAULT_PORT)) }
      end

      uri = URI.parse(endpoint.include?("://") ? endpoint : "redis://#{endpoint}")
      unless %w[redis rediss].include?(uri.scheme)
        raise ArgumentError, "Unsupported cluster URL scheme: #{uri.scheme.inspect}"
      end

      { host: uri.host || "127.0.0.1", port: uri.port || DEFAULT_PORT }
    rescue URI::InvalidURIError => error
      raise ArgumentError, "Invalid cluster node: #{error.message}", cause: error
    end
  end
end
