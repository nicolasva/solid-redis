# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create do |task|
  task.test_globs = ["test/**/*_test.rb"]
  task.warning = true
end

task default: %i[test build]
