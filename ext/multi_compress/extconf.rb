# frozen_string_literal: true

require "mkmf"

USE_SYSTEM = arg_config("--use-system-libraries") ||
             ENV["COMPRESS_USE_SYSTEM_LIBRARIES"]
FORCE_VENDORED = arg_config("--force-vendored") ||
                 ENV["COMPRESS_FORCE_VENDORED"]
DISABLE_ZSTD_ASM = arg_config("--disable-zstd-asm") ||
                   ENV["MULTI_COMPRESS_DISABLE_ZSTD_ASM"] == "1"

ZSTD_SUBDIRS   = %w[lib/common lib/compress lib/decompress lib/dictBuilder].freeze
BROTLI_SUBDIRS = %w[c/common c/enc c/dec].freeze
LZ4_SOURCES    = %w[lz4.c lz4hc.c lz4frame.c].freeze
BROTLI_STATIC_INIT_SOURCES = %w[
  c/enc/static_init.c
  c/dec/static_init.c
].freeze
BROTLI_STATIC_INIT_WRAPPERS = %w[
  brotli_enc_static_init.c
  brotli_dec_static_init.c
].freeze

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

def zstd_asm_supported?
  case RUBY_PLATFORM
  when /x86_64|amd64/
    !RUBY_PLATFORM.include?("mswin") && !RUBY_PLATFORM.include?("mingw")
  else
    false
  end
end

def configure_system_libraries
  puts "Building with SYSTEM libraries"

  configure_homebrew if RUBY_PLATFORM.include?("darwin")

  require_system_lib("zstd",   header: "zstd.h",           func: "ZSTD_compress")
  require_system_lib("lz4",    header: "lz4.h",            func: "LZ4_compress_default")
  require_system_lib("brotli", header: "brotli/encode.h",  func: "BrotliEncoderCreateInstance", lib: "brotlienc")

  have_header("zdict.h")
  have_header("lz4hc.h")
  have_header("lz4frame.h")
  have_library("lz4", "LZ4_compress_HC")
  have_library("lz4", "LZ4F_compressFrame")
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
  puts "  forced vendored mode enabled" if FORCE_VENDORED
  puts "  #{versions.tr("\n", ", ")}"

  zstd_dir   = File.join(vendor_dir, "zstd")
  lz4_dir    = File.join(vendor_dir, "lz4")
  brotli_dir = File.join(vendor_dir, "brotli")

  all_vendor_srcs = collect_vendor_sources(zstd_dir, lz4_dir, brotli_dir)

  puts "  #{all_vendor_srcs.length} vendored C files"

  add_include_dirs(zstd_dir, lz4_dir, brotli_dir)
  if DISABLE_ZSTD_ASM
    $CPPFLAGS += " -DZSTD_DISABLE_ASM"
    puts "  ZSTD ASM Huffman decoder disabled (--disable-zstd-asm or MULTI_COMPRESS_DISABLE_ZSTD_ASM=1)"
  end

  vpath_dirs = build_vpath_dirs(zstd_dir, lz4_dir, brotli_dir)

  deduplicate_sources!(all_vendor_srcs)

  compress_c_dir = find_compress_c_dir

  c_srcs   = all_vendor_srcs.reject { |s| s.end_with?(".S") }
  asm_srcs = all_vendor_srcs.select { |s| s.end_with?(".S") }

  $srcs  = ["multi_compress.c"] + c_srcs.map { |s| File.basename(s) }
  $VPATH = [compress_c_dir] + vpath_dirs

  $multi_compress_asm_srcs = asm_srcs

  $warnflags = ""

  vpath_dirs
end

def collect_vendor_sources(zstd_dir, lz4_dir, brotli_dir)
  zstd_srcs = ZSTD_SUBDIRS.flat_map { |d| Dir[File.join(zstd_dir, d, "*.c")] }

  unless DISABLE_ZSTD_ASM
    asm = File.join(zstd_dir, "lib", "decompress", "huf_decompress_amd64.S")
    zstd_srcs << asm if File.exist?(asm) && zstd_asm_supported?
  end

  lz4_srcs = LZ4_SOURCES.filter_map do |f|
    path = File.join(lz4_dir, "lib", f)
    path if File.exist?(path)
  end

  brotli_srcs = BROTLI_SUBDIRS.flat_map { |d| Dir[File.join(brotli_dir, d, "*.c")] }

  # Brotli 1.2.0 has both c/enc/static_init.c and c/dec/static_init.c.
  # mkmf builds object files by basename, so compiling both as static_init.c
  # makes one object shadow the other. Use unique wrapper translation units
  # instead; otherwise the decoder static init can be skipped and crash at runtime.
  brotli_static_init_paths = BROTLI_STATIC_INIT_SOURCES.map do |relative_path|
    File.join(brotli_dir, relative_path)
  end
  brotli_srcs -= brotli_static_init_paths

  brotli_static_init_wrappers = BROTLI_STATIC_INIT_WRAPPERS.map do |file|
    File.join(__dir__, file)
  end

  zstd_srcs + lz4_srcs + brotli_srcs + brotli_static_init_wrappers
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

def patch_makefile_asm!(asm_srcs)
  return if asm_srcs.nil? || asm_srcs.empty?

  makefile = File.read("Makefile")
  return if makefile.include?("# vendored asm")

  asm_dirs = asm_srcs.map { |s| File.dirname(s) }.uniq
  vpath_lines = asm_dirs.map { |d| "vpath %.S #{d}" }.join("\n")

  asm_objs = asm_srcs.map { |s| File.basename(s, ".S") + ".o" }
  obj_append = asm_objs.join(" ")

  unless makefile.sub!(/^(OBJS\s*=\s*[^\n]+?)(\s*)$/) { "#{Regexp.last_match(1)} #{obj_append}#{Regexp.last_match(2)}" }
    makefile << "\nOBJS = #{obj_append}\n"
  end

  pattern_rule = <<~MAKE
    # vendored asm
    #{vpath_lines}
    %.o: %.S
    \t$(ECHO) compiling $(<)
    \t$(Q) $(CC) $(INCFLAGS) $(CPPFLAGS) $(CFLAGS) -c -o $@ $<
  MAKE

  makefile << "\n#{pattern_rule}\n"

  File.write("Makefile", makefile)
  puts "  Patched Makefile with #{asm_srcs.length} ASM source(s): #{asm_objs.join(", ")}"
end

# --- Main ---

VENDOR_DIR = find_vendor_dir
VENDORED   = !VENDOR_DIR.nil?

if FORCE_VENDORED && !VENDORED
  abort "COMPRESS_FORCE_VENDORED is set, but ext/multi_compress/vendor/.vendored was not found"
end

if FORCE_VENDORED
  vpath_dirs = configure_vendored_libraries(VENDOR_DIR)
elsif USE_SYSTEM || !VENDORED
  configure_system_libraries
  vpath_dirs = nil
else
  vpath_dirs = configure_vendored_libraries(VENDOR_DIR)
end

$CFLAGS += " -O3"
$CFLAGS += " -DXXH_NAMESPACE=MULTICOMPRESS_"

case RUBY_PLATFORM
when /x86_64|amd64|aarch64|arm64/
  $CFLAGS += " -DBROTLI_BUILD_LITTLE_ENDIAN"
end

have_header("ruby/fiber/scheduler.h")

have_library("pthread") unless RUBY_PLATFORM.include?("darwin")

create_makefile("multi_compress/multi_compress")

patch_makefile_vpath!(vpath_dirs) if VENDORED && !USE_SYSTEM && vpath_dirs
patch_makefile_asm!($multi_compress_asm_srcs) if VENDORED && !USE_SYSTEM && $multi_compress_asm_srcs
