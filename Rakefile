# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib' << 'test'
  t.test_files = FileList['test/**/*_test.rb']
  t.warning = false
end

Rake::TestTask.new('test:unit') do |t|
  t.libs << 'lib' << 'test'
  t.test_files = FileList['test/unit/**/*_test.rb']
end

Rake::TestTask.new('test:integration') do |t|
  t.libs << 'lib' << 'test'
  t.test_files = FileList['test/integration/**/*_test.rb']
end

task default: :test
