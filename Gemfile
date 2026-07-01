# frozen_string_literal: true

source "https://rubygems.org"

gemspec

gem "rake", "~> 13.0"
gem "rake-compiler", "~> 1.2"
gem "minitest", "~> 5.0"

group :modern_development, optional: true do
  gem "async", ">= 2.0", "< 2.25", require: false
  gem "memory_profiler", "~> 1.0", require: false
  gem "benchmark-ips", "~> 2.0", require: false
end
