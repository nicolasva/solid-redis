# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create do |task|
  task.test_globs = ["test/**/*_test.rb"]
  task.warning = true
end

desc "Run the deterministic local throughput benchmark"
task :benchmark do
  ruby "benchmark/throughput.rb"
end

namespace :benchmark do
  desc "Compare solid-redis with redis-client against real Redis topologies"
  task :comparison do
    ruby "benchmark/comparison.rb"
  end

  desc "Run the comparison benchmark and publish its tables in README.md"
  task :publish do
    sh({ "BENCHMARK_README" => "README.md" }, RbConfig.ruby, "benchmark/comparison.rb")
  end
end

task default: %i[test benchmark build]
