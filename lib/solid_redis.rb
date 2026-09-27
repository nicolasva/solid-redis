# frozen_string_literal: true

require "base_service"
require "callback_collection"

require_relative "solid_redis/version"
require_relative "solid_redis/errors"
require_relative "solid_redis/shareable"
require_relative "solid_redis/config"
require_relative "solid_redis/resp"
require_relative "solid_redis/client"
require_relative "solid_redis/sentinel/resolve_service"
require_relative "solid_redis/sentinel_state"
require_relative "solid_redis/sentinel_config"
require_relative "solid_redis/pool"

module SolidRedis
  module_function

  def config(**options)
    Config.new(**options)
  end

  def sentinel(**options)
    SentinelConfig.new(**options)
  end
end
