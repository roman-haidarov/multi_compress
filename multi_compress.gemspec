require_relative "lib/multi_compress/version"

Gem::Specification.new do |spec|
  spec.name          = "multi_compress"
  spec.version       = MultiCompress::VERSION
  spec.authors       = ["Roman Haydarov"]
  spec.email         = ["romnhajdarov@gmail.com"]

  spec.summary       = "Modern fiber-friendly compression for Ruby: zstd, lz4, brotli in one gem"
  spec.description   = "Unified C-extension gem for zstd, lz4, and brotli compression. " \
                        "One-shot, streaming, IO wrappers, dictionary support. " \
                        "Fiber-friendly: cooperates with Fiber::Scheduler (async, falcon) " \
                        "so CPU-heavy compression never blocks the event loop. " \
                        "Ships vendored sources — no system libraries required."
  spec.homepage      = "https://github.com/roman-haidarov/multi_compress"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 2.7.1"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "docs/**/*.md",
    "ext/**/*.{c,h,rb}",
    "ext/multi_compress/vendor/**/*",
    "ext/multi_compress/vendor/.vendored",
    "db_core/**/*.{c,h}",
    "postgres_extension/**/*",
    "mysql_udf/**/*",
    "db_deployment/**/*",
    "multi_compress.gemspec",
    "README.md",
    "GET_STARTED.md",
    "LICENSE.txt",
    "THIRD_PARTY_NOTICES.md",
    "CHANGELOG.md"
  ].reject do |path|
    File.basename(path) == ".DS_Store" ||
      path.split(File::SEPARATOR).include?("build") ||
      %w[.o .so .bundle .dylib .bc .d].include?(File.extname(path))
  end

  spec.bindir        = "exe"
  spec.executables   = ["multi_compress"]
  spec.require_paths = ["lib"]
  spec.extensions    = ["ext/multi_compress/extconf.rb"]

  spec.add_development_dependency "bundler", "~> 2.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rake-compiler", "~> 1.2"
  spec.add_development_dependency "minitest", "~> 5.0"
end
