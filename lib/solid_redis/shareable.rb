# frozen_string_literal: true

module SolidRedis
  module Shareable
    module_function

    def copy(value, label:)
      Ractor.make_shareable(value, copy: true)
    rescue Ractor::Error, TypeError => error
      raise ArgumentError, "#{label} must be Ractor-shareable: #{error.message}", cause: error
    end
  end
end
