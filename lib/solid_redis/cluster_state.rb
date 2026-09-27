# frozen_string_literal: true

module SolidRedis
  # Per-Ractor Cluster runtime: the slot table, the node configurations and
  # the mutex protecting them. Never shared between Ractors.
  class ClusterState
    def initialize(specification)
      @specification = specification
      @mutex = Mutex.new
      @slots = Array.new(Cluster::KeySlot::SLOTS)
      @nodes = {}
      @discovered = false
    end

    def discovered?
      @mutex.synchronize { @discovered }
    end

    # Returns the master Config owning +slot+, discovering the topology when
    # it is not known yet.
    def node_for_slot(slot)
      @mutex.synchronize do
        discover unless @discovered
        key = @slots[slot]
        if key.nil?
          discover
          key = @slots[slot]
        end
        @nodes[key] || raise(ConnectionError, "No cluster node serves slot #{slot}")
      end
    end

    def nodes
      @mutex.synchronize do
        discover unless @discovered
        @nodes.values
      end
    end

    def any_node
      nodes.first
    end

    # Applies a MOVED redirection locally without a full topology refresh.
    def move(slot, host, port)
      @mutex.synchronize do
        key = node_key(host, port)
        @nodes[key] ||= node_config(host, port)
        @slots[slot] = key
        @nodes[key]
      end
    end

    def node(host, port)
      @mutex.synchronize { @nodes[node_key(host, port)] ||= node_config(host, port) }
    end

    def reset
      @mutex.synchronize do
        @discovered = false
        @slots.fill(nil)
        @nodes.clear
      end
    end

    def refresh
      @mutex.synchronize { discover }
    end

    private

    # Must be called with the mutex held.
    def discover
      endpoints = @nodes.values.map { |config| { host: config.host, port: config.port } }
      endpoints |= @specification.node_endpoints
      result = Cluster::DiscoverService.call(specification: @specification, endpoints: endpoints)
      unless result.successful? && result.result
        details = result.errors.map(&:message).join("; ")
        raise ConnectionError, "No cluster node reachable: #{details}"
      end

      @slots.fill(nil)
      @nodes.clear
      result.result[:ranges].each do |range|
        key = node_key(range[:master][:host], range[:master][:port])
        @nodes[key] ||= node_config(range[:master][:host], range[:master][:port])
        (range[:from]..range[:to]).each { |slot| @slots[slot] = key }
      end
      @discovered = true
      @specification.notify(:resolved, "cluster", @nodes.keys.join(","))
    end

    def node_key(host, port)
      "#{host}:#{port}"
    end

    # Node clients never retry on their own: ClusterClient owns the retry so
    # that a topology refresh happens between attempts.
    def node_config(host, port)
      Config.new(**@specification.redis_client_options, host: host, port: port, reconnect_attempts: 0)
    end
  end
end
