# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/**/*_test.rb"
  t.warning = true
end

desc "Run only source-related tests"
Rake::TestTask.new(:test_sources) do |t|
  t.libs << "test"
  t.pattern = "test/**/*source*_test.rb"
  t.warning = true
end

desc "Run only target-related tests"
Rake::TestTask.new(:test_targets) do |t|
  t.libs << "test"
  t.pattern = "test/**/*target*_test.rb"
  t.warning = true
end

desc "Run only report-related tests"
Rake::TestTask.new(:test_reports) do |t|
  t.libs << "test"
  t.pattern = "test/**/*report*_test.rb"
  t.warning = true
end

task default: :test
