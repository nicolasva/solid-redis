# frozen_string_literal: true

module SolidRedis
  module Sentinel
    class ResolveService < Service::Base
      def call
        @endpoints.each do |endpoint|
          client = Config.new(**@specification.sentinel_client_options, **endpoint).new_client
          target = resolve_target(client)
          unless target
            append_error(
              :target_not_found,
              "#{endpoint_label(endpoint)} does not know #{@specification.name.inspect}",
            )
            next
          end

          return {
            target: target,
            endpoint: endpoint,
            discovered: discover_sentinels(client),
          }
        rescue SolidRedis::Error, KeyError, ArgumentError => error
          append_error(:sentinel_unavailable, "#{endpoint_label(endpoint)}: #{error.message}")
          sleep SentinelState::SENTINEL_DELAY
        ensure
          client&.close
        end

        nil
      end

      private

      def resolve_target(client)
        if @specification.role == :master
          resolve_master(client)
        else
          resolve_replica(client)
        end
      end

      def resolve_master(client)
        response = client.call("SENTINEL", "get-master-addr-by-name", @specification.name)
        return unless response && response[0] && response[1]

        { host: response[0], port: Integer(response[1]) }
      end

      def resolve_replica(client)
        replicas = client.call("SENTINEL", "replicas", @specification.name)
        candidates = replicas.filter_map do |entry|
          attributes = attributes(entry)
          flags = attributes["flags"].to_s.split(",")
          next if flags.any? { |flag| %w[s_down o_down disconnected].include?(flag) }

          { host: attributes.fetch("ip"), port: Integer(attributes.fetch("port")) }
        end
        candidates.sample
      end

      def discover_sentinels(client)
        client.call("SENTINEL", "sentinels", @specification.name).map do |entry|
          values = attributes(entry)
          { host: values.fetch("ip"), port: Integer(values.fetch("port")) }
        end
      end

      def attributes(entry)
        entry.is_a?(Hash) ? entry : Hash[*entry]
      end

      def endpoint_label(endpoint)
        "#{endpoint[:host]}:#{endpoint[:port]}"
      end
    end
  end
end
