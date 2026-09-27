# frozen_string_literal: true

module SolidRedis
  module Cluster
    # Queries CLUSTER SLOTS on the first reachable node and returns the slot
    # table as a list of ranges:
    #
    #   { ranges: [{ from:, to:, master: { host:, port: }, replicas: [...] }], endpoint: }
    class DiscoverService < Service::Base
      def call
        @endpoints.each do |endpoint|
          client = Config.new(**@specification.redis_client_options, **endpoint).new_client
          ranges = client.call("CLUSTER", "SLOTS").map { |entry| range(entry, endpoint) }
          if ranges.empty?
            append_error(:empty_topology, "#{endpoint_label(endpoint)} returned no slots")
            next
          end

          return { ranges: ranges, endpoint: endpoint }
        rescue SolidRedis::Error, KeyError, ArgumentError, TypeError => error
          append_error(:node_unavailable, "#{endpoint_label(endpoint)}: #{error.message}")
        ensure
          client&.close
        end

        nil
      end

      private

      def range(entry, endpoint)
        from, to, master, *replicas = entry
        {
          from: Integer(from),
          to: Integer(to),
          master: node(master, endpoint),
          replicas: replicas.map { |replica| node(replica, endpoint) },
        }
      end

      # A node may announce an empty host, meaning "the address you used".
      def node(entry, endpoint)
        host, port = entry
        host = endpoint[:host] if host.nil? || host.to_s.empty?
        { host: host, port: Integer(port) }
      end

      def endpoint_label(endpoint)
        "#{endpoint[:host]}:#{endpoint[:port]}"
      end
    end
  end
end
