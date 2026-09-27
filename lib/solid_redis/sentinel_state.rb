# frozen_string_literal: true

module SolidRedis
  class SentinelState
    SENTINEL_DELAY = 0.05

    def initialize(specification)
      @specification = specification
      @sentinels = specification.sentinel_endpoints.dup
      @resolved = nil
      @mutex = Mutex.new
    end

    def resolve
      @mutex.synchronize do
        @resolved ||= resolve_target
      end
    end

    def reset
      @mutex.synchronize { @resolved = nil }
    end

    def resolved?
      @mutex.synchronize { !@resolved.nil? }
    end

    def sentinel_endpoints
      @mutex.synchronize { @sentinels.dup }
    end

    private

    def resolve_target
      result = Sentinel::ResolveService.call(
        specification: @specification,
        endpoints: @sentinels.dup,
      )
      unless result.successful? && result.result
        details = result.errors.map(&:message).join("; ")
        raise ConnectionError, "No Sentinel available for #{@specification.name.inspect}: #{details}"
      end

      resolution = result.result
      resolution[:discovered].each do |attributes|
        endpoint = Shareable.copy(
          attributes,
          label: "discovered Sentinel",
        )
        @sentinels << endpoint unless same_endpoint?(endpoint)
      end
      promote(resolution[:endpoint])
      target = Config.new(**@specification.redis_client_options, **resolution[:target])
      @specification.notify(:resolved, @specification.name, target.server_url)
      target
    end

    def same_endpoint?(candidate)
      @sentinels.any? do |endpoint|
        endpoint[:host] == candidate[:host] && endpoint[:port] == candidate[:port]
      end
    end

    def promote(endpoint)
      @sentinels.delete(endpoint)
      @sentinels.unshift(endpoint)
    end
  end
end
