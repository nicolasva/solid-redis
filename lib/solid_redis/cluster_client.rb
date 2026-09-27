# frozen_string_literal: true

module SolidRedis
  # Routes commands to the cluster node owning their key slot and follows
  # MOVED/ASK redirections. Holds one Client per node; all of them belong to
  # the Ractor that created this object.
  class ClusterClient
    REDIRECTION = /\A(MOVED|ASK) (\d+) (\S+):(\d+)\z/
    RETRY_DELAY = 0.05

    attr_reader :config

    def initialize(config, name: nil)
      @config = config
      @name = name
      @clients = {}
    end

    def call(*command)
      call_v(command)
    end

    def call_v(command)
      route(command) { |client| client.call_v(command) }
    end

    def blocking_call(timeout, *command)
      blocking_call_v(timeout, command)
    end

    def blocking_call_v(timeout, command)
      route(command, retry_connection: false) { |client| client.blocking_call_v(timeout, command) }
    end

    # Groups commands by node, runs one pipeline per node and restores the
    # original order. Redirected commands are replayed individually.
    def pipelined(exception: true)
      pipeline = Client::Pipeline.new
      yield pipeline
      commands = pipeline.commands
      return [] if commands.empty?

      results = Array.new(commands.length)
      commands.each_with_index.group_by { |command, _| node_for(command) }.each do |node, group|
        replies = client_for(node).pipelined(exception: false) do |batch|
          group.each { |command, _| batch.call_v(command) }
        end
        group.each_with_index { |(_, index), position| results[index] = replies[position] }
      end

      results.each_with_index do |result, index|
        next unless result.is_a?(CommandError) && result.message.match?(REDIRECTION)

        results[index] = begin
          call_v(commands[index])
        rescue CommandError => error
          error
        end
      end

      if exception && (error = results.find { |result| result.is_a?(CommandError) })
        raise error
      end

      results
    end

    def connected?
      @clients.values.any?(&:connected?)
    end

    def close
      clients = @clients.values
      @clients = {}
      clients.each(&:close)
      self
    end

    def server_url
      @clients.keys.join(",")
    end

    private

    def route(command, retry_connection: true)
      node = node_for(command)
      redirections = 0
      attempts = 0
      asking = false

      loop do
        client = client_for(node)
        client.call_v(["ASKING"]) if asking
        return yield(client)
      rescue CommandError => error
        redirection = error.message.match(REDIRECTION)
        if redirection
          redirections += 1
          raise FailoverError, "Too many cluster redirections: #{error.message}" if redirections > config.max_redirections

          slot = Integer(redirection[2])
          host = redirection[3]
          port = Integer(redirection[4])
          asking = redirection[1] == "ASK"
          node = asking ? config.state.node(host, port) : config.state.move(slot, host, port)
        elsif error.message.start_with?("TRYAGAIN", "CLUSTERDOWN")
          redirections += 1
          raise FailoverError, "Cluster unavailable: #{error.message}" if redirections > config.max_redirections

          sleep RETRY_DELAY
          config.state.refresh
          node = node_for(command)
        else
          raise
        end
      rescue ConnectionError => error
        drop(node)
        raise unless retry_connection && attempts < config.reconnect_attempts

        attempts += 1
        config.notify(:connection_error, error.class.name, error.message)
        config.state.refresh
        node = node_for(command)
      end
    end

    def node_for(command)
      key = Cluster::CommandKey.for(command)
      key ? config.state.node_for_slot(Cluster::KeySlot.for(key)) : config.state.any_node
    end

    def client_for(node)
      @clients[node.server_key] ||= node.new_client(name: @name)
    end

    def drop(node)
      @clients.delete(node.server_key)&.close
    end
  end
end
