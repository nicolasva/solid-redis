# frozen_string_literal: true

require_relative "lib/solid_redis/version"

Gem::Specification.new do |spec|
  spec.name = "solid-redis"
  spec.version = SolidRedis::VERSION
  spec.authors = ["Nicolas Vandenbogaerde"]

  spec.summary = "A Ractor-aware Redis client with Sentinel, Cluster, Pub/Sub and blocking command support"
  spec.description = "Immutable, shareable Redis, Sentinel and Cluster configuration with isolated runtime state, pools, and sockets per Ractor. Supports pipelines, blocking commands, and Pub/Sub."
  spec.homepage = "https://github.com/nicolasva/solid-redis"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["documentation_uri"] = "https://www.rubydoc.info/gems/solid-redis/#{spec.version}"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.add_dependency "base-service", "~> 0.1"
  spec.add_dependency "callback-collection", "~> 0.2"
  spec.add_dependency "solid-resp-ractor", "~> 0.1.4"

  spec.add_development_dependency "minitest", ">= 5", "< 7"
  spec.add_development_dependency "rake", "~> 13.0"
end
