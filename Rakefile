require "bundler/gem_tasks"
require "rake/testtask"
require "rake/extensiontask"

Rake::ExtensionTask.new("multi_compress") do |ext|
  ext.lib_dir = "lib/multi_compress"
  ext.ext_dir = "ext/multi_compress"
end

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb", "test/**/test_*.rb"]
end

desc "Download and vendor C library sources (run before gem build)"
task :vendor do
  ruby "script/vendor_libs.rb"
end

desc "Vendor libs, compile, and test"
task :full_build => [:vendor, :compile, :test]

task default: [:compile, :test]

task :console => :compile do
  require "irb"
  require_relative "lib/multi_compress"
  ARGV.clear
  IRB.start
end
