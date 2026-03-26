# frozen_string_literal: true

require "mkmf"

USE_SYSTEM = arg_config("--use-system-libraries") ||
             ENV["COMPRESS_USE_SYSTEM_LIBRARIES"]

ZSTD_SUBDIRS   = %w[lib/common lib/multi_compress lib/decompress lib/dictBuilder].freeze
BROTLI_SUBDIRS = %w[c/common c/enc c/dec].freeze
LZ4_SOURCES    = %w[lz4.c lz4hc.c lz4frame.c].freeze

def find_vendor_dir
  candidates = [
    File.join(__dir__, "vendor"),
    File.join(__dir__, "..", "..", "..", "..", "ext", "multi_compress", "vendor"),
    File.expand_path("../../ext/multi_compress/vendor", __dir__),
    File.join(Dir.pwd, "ext", "multi_compress", "vendor"),
  ]

  dir = __dir__
  6.times do
    candidates << File.join(dir, "ext", "multi_compress", "vendor")
    dir = File.dirname(dir)
  end

  candidates.find { |path| File.exist?(File.join(path, ".vendored")) }
            &.then { |path| File.expand_path(path) }
end

def find_compress_c_dir
  candidates = [
    __dir__,
    File.join(__dir__, "..", "..", "..", "..", "ext", "multi_compress"),
  ]

  dir = __dir__
  6.times do
    candidates << File.join(dir, "ext", "multi_compress")
    dir = File.dirname(dir)
  end

  candidates.find { |path| File.exist?(File.join(path, "multi_compress.c")) }
            &.then { |path| File.expand_path(path) } || __dir__
end

def configure_system_libraries
  puts "Building with SYSTEM libraries"

  configure_homebrew if RUBY_PLATFORM.include?("darwin")

  require_system_lib("zstd",   header: "zstd.h",           func: "ZSTD_compress")
  require_system_lib("lz4",    header: "lz4.h",            func: "LZ4_compress_default")
  require_system_lib("brotli", header: "brotli/encode.h",  func: "BrotliEncoderCreateInstance", lib: "brotlienc")

  have_header("zdict.h")
  have_header("lz4hc.h")
  have_library("lz4", "LZ4_compress_HC")
  have_header("brotli/decode.h")
  have_library("brotlidec", "BrotliDecoderCreateInstance")
end

def configure_homebrew
  dir_config("homebrew", "/opt/homebrew")
  $CPPFLAGS += " -I/opt/homebrew/include"
  $LDFLAGS  += " -L/opt/homebrew/lib"
end

def require_system_lib(name, header:, func:, lib: name)
  return if have_header(header) && have_library(lib, func)

  abort "Missing #{name}. Install: apt install lib#{name}-dev / brew install #{name}"
end

def configure_vendored_libraries(vendor_dir)
  versions = File.read(File.join(vendor_dir, ".vendored"))
  puts "Building with VENDORED libraries from #{vendor_dir}"
  puts "  #{versions.tr("\n", ", ")}"

  zstd_dir   = File.join(vendor_dir, "zstd")
  lz4_dir    = File.join(vendor_dir, "lz4")
  brotli_dir = File.join(vendor_dir, "brotli")

  all_vendor_srcs = collect_vendor_sources(zstd_dir, lz4_dir, brotli_dir)

  puts "  #{all_vendor_srcs.length} vendored C files"

  add_include_dirs(zstd_dir, lz4_dir, brotli_dir)

  vpath_dirs = build_vpath_dirs(zstd_dir, lz4_dir, brotli_dir)

  deduplicate_sources!(all_vendor_srcs)

  compress_c_dir = find_compress_c_dir

  $srcs  = ["multi_compress.c"] + all_vendor_srcs.map { |s| File.basename(s) }
  $VPATH = [compress_c_dir] + vpath_dirs

  $warnflags = ""

  vpath_dirs
end

def collect_vendor_sources(zstd_dir, lz4_dir, brotli_dir)
  zstd_srcs = ZSTD_SUBDIRS.flat_map { |d| Dir[File.join(zstd_dir, d, "*.c")] }

  lz4_srcs = LZ4_SOURCES.filter_map do |f|
    path = File.join(lz4_dir, "lib", f)
    path if File.exist?(path)
  end

  brotli_srcs = BROTLI_SUBDIRS.flat_map { |d| Dir[File.join(brotli_dir, d, "*.c")] }

  zstd_srcs + lz4_srcs + brotli_srcs
end

def add_include_dirs(zstd_dir, lz4_dir, brotli_dir)
  [
    File.join(zstd_dir, "lib"),
    File.join(zstd_dir, "lib", "common"),
    File.join(lz4_dir, "lib"),
    File.join(brotli_dir, "c", "include"),
  ].each { |d| $CPPFLAGS += " -I#{d}" }
end

def build_vpath_dirs(zstd_dir, lz4_dir, brotli_dir)
  ZSTD_SUBDIRS.map { |d| File.join(zstd_dir, d) } +
    [File.join(lz4_dir, "lib")] +
    BROTLI_SUBDIRS.map { |d| File.join(brotli_dir, d) }
end

def deduplicate_sources!(sources)
  seen = {}

  sources.reject! do |src|
    basename = File.basename(src)
    duplicate = seen.key?(basename)
    puts "  SKIP duplicate: #{src}" if duplicate
    seen[basename] = true
    duplicate
  end
end

def patch_makefile_vpath!(vpath_dirs)
  makefile = File.read("Makefile")
  return if makefile.include?("# vendored vpath")

  vpath_lines = vpath_dirs.map { |d| "vpath %.c #{d}" }.join("\n")

  makefile.sub!(/^(VPATH\s*=.*)$/m) { "#{Regexp.last_match(1)}\n# vendored vpath\n#{vpath_lines}" }
  File.write("Makefile", makefile)
  puts "  Patched Makefile with #{vpath_dirs.length} VPATH entries"
end

# --- Main ---

VENDOR_DIR = find_vendor_dir
VENDORED   = !VENDOR_DIR.nil?

if USE_SYSTEM || !VENDORED
  configure_system_libraries
  vpath_dirs = nil
else
  vpath_dirs = configure_vendored_libraries(VENDOR_DIR)
end

$CFLAGS += " -O2"
$CFLAGS += " -DXXH_NAMESPACE=MULTICOMPRESS_"

create_makefile("multi_compress/multi_compress")

patch_makefile_vpath!(vpath_dirs) if VENDORED && !USE_SYSTEM && vpath_dirs
