# Get Started with MultiCompress 🚀

Comprehensive guide to using **MultiCompress** gem for modern compression in Ruby.

## Installation

```ruby
gem 'multi_compress'
```

## Quick Start

### Basic MultiCompression

```ruby
require 'multi_compress'

data = "Hello, world!" * 1000

# MultiCompress with different algorithms
zstd_data = MultiCompress.compress(data, algo: :zstd)
lz4_data = MultiCompress.compress(data, algo: :lz4)  
brotli_data = MultiCompress.compress(data, algo: :brotli)

# Decompress (auto-detects algorithm for ZSTD and LZ4)
original = MultiCompress.decompress(zstd_data)  # Auto-detects ZSTD
puts original == data  # => true

# Brotli requires explicit algorithm specification
brotli_original = MultiCompress.decompress(brotli_data, algo: :brotli)
puts brotli_original == data  # => true
```

### Important Notes on Algorithm Detection

**Auto-detection behavior:**
- **ZSTD**: Automatically detected by magic bytes `28 B5 2F FD` (little-endian)
- **LZ4**: Auto-detected by internal format validation (see LZ4 format note below)
- **Brotli**: Requires explicit `algo: :brotli` - no auto-detection available

**LZ4 Internal Format Warning:**
This gem uses a **custom internal LZ4 format** that is **NOT compatible** with the standard `lz4` command-line tool. The internal format includes:
- 4 bytes: original size (little-endian)
- 4 bytes: compressed size (little-endian)  
- N bytes: LZ4 compressed data
- 4 bytes: end marker (`00 00 00 00`)

This format is optimized for streaming and provides better error detection, but files compressed with this gem cannot be decompressed with standard `lz4` CLI tools and vice versa.

**❌ WRONG - This will NOT work:**
```bash
# DON'T DO THIS - These formats are incompatible!

# MultiCompress with Ruby gem
ruby -r multi_compress -e "File.write('data.lz4', MultiCompress.compress('Hello World', algo: :lz4))"

# Try to decompress with CLI tool - FAILS!
lz4 -d data.lz4 data.txt
# => Error: MultiCompressed file is corrupted

# OR vice versa:
echo "Hello World" | lz4 > data.lz4

# Try to decompress with gem - FAILS!  
ruby -r multi_compress -e "puts MultiCompress.decompress(File.read('data.lz4'))"
# => MultiCompress::DataError: cannot detect compression format
```

**✅ CORRECT - Use consistent tools:**
```ruby
# MultiCompress and decompress with same gem
data = "Hello World"
compressed = MultiCompress.compress(data, algo: :lz4)
original = MultiCompress.decompress(compressed)  # Works perfectly!
```

**Security Features:**
- Default one-shot decompression output cap: **512MB**
- Default streaming cumulative output cap: **2GB**
- `MultiCompress.configure` lets applications set global defaults
- Per-call `max_output_size:` overrides keep local business logic explicit
- `MultiCompress::Dictionary.load` rejects dictionary files larger than **32MB**
- Invalid or corrupted data raises `MultiCompress::DataError` with descriptive messages

```ruby
MultiCompress.configure do |config|
  config.max_output_size = 512 * 1024 * 1024
  config.streaming_max_output_size = 2 * 1024 * 1024 * 1024
end

# Tighten the output cap for untrusted input
MultiCompress.decompress(zstd_data, algo: :zstd, max_output_size: 8 * 1024 * 1024)
```

### Algorithm-specific Shortcuts

```ruby
# Quick compression with defaults
compressed = MultiCompress.zstd(data)      # level: 3
compressed = MultiCompress.lz4(data)       # level: 1  
compressed = MultiCompress.brotli(data)    # level: 6

# With custom levels
compressed = MultiCompress.zstd(data, level: 9)
compressed = MultiCompress.brotli(data, level: 11)  # maximum compression
```

### Named MultiCompression Levels

```ruby
# Use semantic names instead of numbers
# Supported names today: :fastest, :default, :best
MultiCompress.compress(data, algo: :zstd, level: :fastest)    # zstd level 1
MultiCompress.compress(data, algo: :zstd, level: :default)    # zstd level 3
MultiCompress.compress(data, algo: :zstd, level: :best)       # zstd level 19

MultiCompress.compress(data, algo: :lz4, level: :fastest)     # lz4 level 1
MultiCompress.compress(data, algo: :lz4, level: :default)     # lz4 level 1
MultiCompress.compress(data, algo: :lz4, level: :best)        # lz4 level 16

MultiCompress.compress(data, algo: :brotli, level: :fastest)  # brotli level 0
MultiCompress.compress(data, algo: :brotli, level: :default)  # brotli level 6
MultiCompress.compress(data, algo: :brotli, level: :best)     # brotli level 11
```

## Streaming MultiCompression

Perfect for processing large datasets, HTTP responses, or real-time data.

### Basic Streaming

```ruby
# MultiCompress data in chunks
deflater = MultiCompress::Deflater.new(algo: :zstd, level: 5)

compressed_chunks = []
compressed_chunks << deflater.write("chunk 1")
compressed_chunks << deflater.write("chunk 2") 
compressed_chunks << deflater.write("chunk 3")
compressed_chunks << deflater.finish  # Important: finalize stream

deflater.close

# Join all compressed data
compressed_data = compressed_chunks.join
```

### Stream Decompression

`MultiCompress.decompress(...)` can auto-detect ZSTD and LZ4 in one-shot mode. `MultiCompress::Inflater` is a streaming API and should be created with an explicit `algo:`.

```ruby
inflater = MultiCompress::Inflater.new(algo: :zstd, max_output_size: 32 * 1024 * 1024)

decompressed_chunks = []
compressed_chunks.each do |chunk|
  decompressed_chunks << inflater.write(chunk)
end
decompressed_chunks << inflater.finish

inflater.close

original_data = decompressed_chunks.join
```

### Advanced Streaming Example

```ruby
def compress_large_file(input_path, output_path)
  deflater = MultiCompress::Deflater.new(algo: :zstd, level: 3)
  
  File.open(input_path, 'rb') do |input|
    File.open(output_path, 'wb') do |output|
      while chunk = input.read(64 * 1024)  # 64KB chunks
        compressed = deflater.write(chunk)
        output.write(compressed) unless compressed.empty?
      end
      
      # Write final chunk
      final_chunk = deflater.finish
      output.write(final_chunk) unless final_chunk.empty?
    end
  end
  
  deflater.close
end
```

## Fiber-friendly Execution

Starting with **v0.2.0**, MultiCompress is fully fiber-friendly and plays nicely with Ruby's `Fiber::Scheduler`-based runtimes like [async](https://github.com/socketry/async) and [falcon](https://github.com/socketry/falcon).

### The Problem It Solves

Compression is CPU-bound work. Historically, calling `zstd`/`lz4`/`brotli` from inside an `Async` block would hold the GVL for the entire duration of the compress/decompress call, freezing the event loop and starving every other fiber — HTTP requests, timers, DB queries, everything. On a 50 MB zstd compression that meant tens to hundreds of milliseconds of total reactor stall.

### How It Works

When MultiCompress detects an active `Fiber::Scheduler`, it:

1. Spawns a **dedicated worker thread** via `rb_thread_create` to run the compression with the GVL released.
2. Parks the calling fiber with `rb_fiber_scheduler_block(scheduler, blocker, Qnil)`.
3. While the worker crunches bytes, the scheduler is free to run **every other ready fiber** — IO, timers, parallel compression tasks, you name it.
4. When the worker finishes, it calls `rb_fiber_scheduler_unblock(scheduler, blocker, fiber)` to resume the original fiber with the result.

Outside of a fiber scheduler, MultiCompress uses the same `rb_thread_call_without_gvl` fast path as before — zero overhead, zero behavior change for non-async users.

### What's Covered

| API                              | zstd | lz4 | brotli |
|----------------------------------|------|-----|--------|
| `MultiCompress.compress`         | ✅    | ✅   | ✅      |
| `MultiCompress.decompress`       | ✅    | ✅   | ✅      |
| `MultiCompress::Deflater#write`  | ✅    | ✅*  | ✅      |
| `MultiCompress::Inflater#write`  | ✅    | ✅*  | ✅      |

<sub>\* LZ4 streaming uses cooperative `scheduler.yield` between 64 KB blocks instead of the worker-thread path — individual LZ4 blocks are too fast (~10μs) for pthread-create overhead (~20-50μs) to be worth it. Other fibers still get scheduling points, just via a lighter mechanism.</sub>

Streaming chunks smaller than **16 KB** (`FIBER_STREAM_THRESHOLD`) stay inline under the GVL to avoid pthread-create overhead on tiny payloads. Production workloads using 64 KB+ chunks get the full benefit.

### Example: Non-blocking Compression Under Async

```ruby
require 'async'
require 'async/http/internet'
require 'multi_compress'

Async do |task|
  # Fiber 1: make HTTP requests every 100ms — this keeps ticking
  # even while the compression fiber is working.
  poller = task.async do
    internet = Async::HTTP::Internet.new
    loop do
      response = internet.get("https://httpbin.org/uuid")
      puts "Got uuid at #{Time.now}: #{response.read[0..20]}"
      task.sleep(0.1)
    end
  ensure
    internet&.close
  end

  # Fiber 2: compress a huge payload. In v0.1.x this would have
  # frozen the poller for the entire duration. In v0.2.0, the
  # poller keeps firing while compression runs on a worker thread.
  compressor = task.async do
    huge_payload = File.read("dataset.json")    # say, 50 MB
    compressed   = MultiCompress.compress(huge_payload, algo: :zstd)
    File.binwrite("dataset.json.zst", compressed)
    puts "Compressed #{huge_payload.bytesize} → #{compressed.bytesize} bytes"
  end

  compressor.wait
  poller.stop
end
```

### Example: Streaming With Concurrent IO

```ruby
require 'async'
require 'multi_compress'

Async do |task|
  # Read incoming network data in one fiber, compress it in another.
  # Both fibers make progress concurrently.
  reader, writer = IO.pipe

  producer = task.async do
    File.open("huge.log", "rb") do |f|
      while chunk = f.read(256 * 1024)
        writer.write(chunk)
      end
    end
    writer.close
  end

  compressor = task.async do
    deflater = MultiCompress::Deflater.new(algo: :zstd, level: 3)
    File.open("huge.log.zst", "wb") do |out|
      while chunk = reader.read(256 * 1024)
        # Each 256 KB deflater.write runs on a worker thread when
        # a scheduler is active — the producer fiber keeps reading
        # the pipe in parallel.
        out.write(deflater.write(chunk))
      end
      out.write(deflater.finish)
    end
    deflater.close
    reader.close
  end

  [producer, compressor].each(&:wait)
end
```

### Parallel Compression Across Fibers

Because each compression call blocks only its own fiber, you can fan out multiple compressions and the scheduler will overlap them with each other (and with any other IO fibers):

```ruby
require 'async'
require 'async/barrier'
require 'multi_compress'

files = Dir.glob("logs/*.log")
results = {}

Async do |task|
  barrier = Async::Barrier.new

  files.each do |path|
    barrier.async do
      data = File.read(path)
      results[path] = MultiCompress.compress(data, algo: :zstd)
    end
  end

  barrier.wait
end

results.each do |path, compressed|
  File.binwrite("#{path}.zst", compressed)
end
```

### Requirements

- Ruby **>= 3.1.0**
- A running `Fiber::Scheduler` — typically provided by `Async { ... }` or Falcon's web server

### No Code Changes Required

If you're already using MultiCompress under Async or Falcon, upgrading to v0.2.0 gives you non-blocking compression automatically. No new API, no config flags, nothing to opt into. Just upgrade the gem.

## File I/O Integration

### Writing MultiCompressed Files

```ruby
# Simple file writing
MultiCompress::Writer.open("data.zst", algo: :zstd, level: 3) do |writer|
  writer.write("Line 1\n")
  writer.write("Line 2\n")
  writer.puts("Line 3")  # adds newline
end

# Auto-detect algorithm by extension
MultiCompress::Writer.open("logs.lz4") do |writer|  # automatically uses LZ4
  1000.times { |i| writer.puts "Log entry #{i}" }
end

# Different file extensions
MultiCompress::Writer.open("api_response.br")   # Brotli (.br)
MultiCompress::Writer.open("backup.zst")        # Zstd (.zst) 
MultiCompress::Writer.open("cache.lz4")         # LZ4 (.lz4)
```

### Reading MultiCompressed Files

```ruby
# Read entire file
content = MultiCompress::Reader.open("data.zst", max_output_size: 64 * 1024 * 1024) { |r| r.read }

# Read line by line (memory efficient)
MultiCompress::Reader.open("large_log.zst") do |reader|
  reader.each_line do |line|
    process_log_entry(line.chomp)
  end
end

# Manual reading
MultiCompress::Reader.open("data.zst") do |reader|
  while chunk = reader.read(1024)
    process_chunk(chunk)
  end
end
```

### In-Memory I/O with StringIO

```ruby
require 'stringio'

# MultiCompress to StringIO
sio = StringIO.new
MultiCompress::Writer.open(sio, algo: :brotli, level: 8) do |writer|
  writer.write({ status: 'ok', data: [1, 2, 3] }.to_json)
end
compressed_json = sio.string

# Decompress from StringIO
sio = StringIO.new(compressed_json)
MultiCompress::Reader.open(sio) do |reader|
  json_data = reader.read
  puts JSON.parse(json_data)
end
```

## Dictionary MultiCompression

Dramatically improves compression on small, similar data (JSON APIs, configs, logs).

**Important**: Dictionary training is available for **Zstd** in the current release (vendored zstd **1.5.2**). Brotli dictionaries can be used, but this gem does not expose Brotli training through `train_dictionary`.

### Training Dictionary (Zstd)

```ruby
# Collect training samples (similar structure)
api_responses = [
  '{"status":"ok","users":[{"id":1,"name":"Alice"}]}',
  '{"status":"ok","users":[{"id":2,"name":"Bob"}]}',
  '{"status":"ok","users":[{"id":3,"name":"Charlie"}]}',
  # ... more samples
]

# Train dictionary for Zstd
zstd_dict = MultiCompress::Zstd.train_dictionary(api_responses, size: 16384)

# Save for reuse
zstd_dict.save("api_v1_zstd.dict")
```

**Brotli note**: `MultiCompress::Brotli.train_dictionary(...)` raises `MultiCompress::UnsupportedError` in the current implementation. To use Brotli dictionaries, create a raw dictionary explicitly with `MultiCompress::Dictionary.new(data, algo: :brotli)`.

### Using Dictionary

```ruby
# Load dictionary (created with Zstd training)
zstd_dict = MultiCompress::Dictionary.load("api_v1_zstd.dict", algo: :zstd)

response = '{"status":"ok","users":[{"id":4,"name":"David"}]}'
compressed = MultiCompress.compress(response, algo: :zstd, dictionary: zstd_dict)
original = MultiCompress.decompress(compressed, algo: :zstd, dictionary: zstd_dict)

# Brotli can also use raw dictionaries
brotli_dict = MultiCompress::Dictionary.new("shared-prefix-data", algo: :brotli)
brotli_compressed = MultiCompress.compress(response, algo: :brotli, dictionary: brotli_dict)
brotli_original = MultiCompress.decompress(brotli_compressed, algo: :brotli, dictionary: brotli_dict)

puts original == response  # => true
```

### Dictionary with Streaming

```ruby
# Load Zstd-trained dictionary
dict = MultiCompress::Dictionary.load("api_v1_zstd.dict", algo: :zstd)

# Compress multiple API responses using Zstd
deflater = MultiCompress::Deflater.new(algo: :zstd, level: 3, dictionary: dict)

api_responses.each do |response|
  compressed = deflater.write(response)
  store_compressed(compressed)
end

deflater.finish
deflater.close
```

## Real-World Examples

### HTTP Middleware (Rails/Rack)

```ruby
class MultiCompressMiddleware
  COMPRESSIBLE_TYPES = %w[
    application/json
    application/xml
    text/html
    text/css
    text/javascript
    application/javascript
  ].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    status, headers, body = @app.call(env)
    
    content_type = headers['Content-Type']&.split(';')&.first
    
    if should_compress?(env, content_type, body)
      compressed_body = compress_body(body, env)
      headers['Content-Encoding'] = compression_algorithm(env)
      headers['Content-Length'] = compressed_body.bytesize.to_s
      [status, headers, [compressed_body]]
    else
      [status, headers, body]
    end
  end

  private

  def should_compress?(env, content_type, body)
    return false unless COMPRESSIBLE_TYPES.include?(content_type)
    return false if body.sum(&:bytesize) < 1024  # Don't compress small responses
    
    accept_encoding = env['HTTP_ACCEPT_ENCODING'] || ''
    %w[br zstd gzip].any? { |enc| accept_encoding.include?(enc) }
  end

  def compress_body(body, env)
    data = body.respond_to?(:join) ? body.join : body.to_s
    
    case compression_algorithm(env)
    when 'br'
      MultiCompress.brotli(data, level: 4)  # Good balance for HTTP
    when 'zstd'  
      MultiCompress.zstd(data, level: 3)    # Fast compression
    else
      data  # fallback
    end
  end

  def compression_algorithm(env)
    accept_encoding = env['HTTP_ACCEPT_ENCODING'] || ''
    return 'br' if accept_encoding.include?('br')
    return 'zstd' if accept_encoding.include?('zstd')
    'gzip'  # fallback
  end
end
```

### Redis Cache with MultiCompression

```ruby
class MultiCompressedRedisCache
  def initialize(redis: Redis.current, algo: :zstd, level: 3)
    @redis = redis
    @algo = algo
    @level = level
  end

  def write(key, value, expires_in: nil)
    serialized = Marshal.dump(value)
    compressed = MultiCompress.compress(serialized, algo: @algo, level: @level)
    
    if expires_in
      @redis.setex(key, expires_in, compressed)
    else
      @redis.set(key, compressed)
    end
  end

  def read(key)
    compressed = @redis.get(key)
    return nil unless compressed
    
    serialized = MultiCompress.decompress(compressed)
    Marshal.load(serialized)
  rescue MultiCompress::Error => e
    Rails.logger.error "Cache decompression failed for #{key}: #{e.message}"
    nil
  end

  def fetch(key, expires_in: nil, &block)
    value = read(key)
    return value if value
    
    value = block.call
    write(key, value, expires_in: expires_in)
    value
  end
end

# Usage
cache = MultiCompressedRedisCache.new(algo: :zstd, level: 5)

# Store complex objects
user_data = { id: 123, name: "Alice", posts: [...] }
cache.write("user:123", user_data, expires_in: 3600)

# Retrieve
user = cache.read("user:123")

# Fetch with fallback
user = cache.fetch("user:456", expires_in: 3600) do
  User.find(456).to_h
end
```

### Background Job Processing

```ruby
class MultiCompressedJobProcessor
  def self.enqueue(job_class, *args)
    payload = { class: job_class.name, args: args }
    serialized = JSON.generate(payload)
    compressed = MultiCompress.zstd(serialized, level: 1)  # Fast compression for queues
    
    Redis.current.lpush("jobs", compressed)
  end

  def self.process_jobs
    while compressed_job = Redis.current.brpop("jobs", timeout: 5)&.last
      begin
        serialized = MultiCompress.decompress(compressed_job)
        payload = JSON.parse(serialized)
        
        job_class = Object.const_get(payload['class'])
        job_class.new.perform(*payload['args'])
      rescue => e
        logger.error "Job processing failed: #{e.message}"
      end
    end
  end
end
```

### Log File Rotation with MultiCompression

```ruby
class MultiCompressedLogger
  def initialize(base_path, max_size: 10 * 1024 * 1024) # 10MB
    @base_path = base_path
    @max_size = max_size
    @current_file = nil
    @current_writer = nil
  end

  def log(message)
    ensure_current_file_open
    
    line = "[#{Time.now.iso8601}] #{message}\n"
    @current_writer.write(line)
    
    rotate_if_needed
  end

  def close
    @current_writer&.close
    @current_file&.close
  end

  private

  def ensure_current_file_open
    return if @current_writer && !@current_writer.closed?
    
    timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
    compressed_path = "#{@base_path}_#{timestamp}.zst"
    
    @current_writer = MultiCompress::Writer.open(compressed_path, algo: :zstd, level: 3)
  end

  def rotate_if_needed
    return unless @current_writer
    
    # Check file size (approximate, since it's compressed)
    if @current_writer.tell > @max_size
      @current_writer.close
      @current_writer = nil
    end
  end
end

# Usage
logger = MultiCompressedLogger.new("/var/log/app/application.log")
logger.log("Application started")
logger.log("Processing request...")
logger.close
```

## Utility Functions

### Algorithm Information

```ruby
# Check available algorithms
MultiCompress.algorithms           # => [:zstd, :lz4, :brotli]

# Check if specific algorithm is available
MultiCompress.available?(:zstd)    # => true
MultiCompress.available?(:fake)    # => false

# Get library versions
MultiCompress.version(:zstd)       # => "1.5.2"
MultiCompress.version(:lz4)        # => "1.10.0"
MultiCompress.version(:brotli)     # => "1.1.0"
```

### Data Integrity

```ruby
# Calculate CRC32 checksum
data = "Important data"
checksum = MultiCompress.crc32(data)  # => Integer

# Verify data integrity
received_data = get_data_from_network()
if MultiCompress.crc32(received_data) == expected_checksum
  puts "Data integrity verified"
end
```

### MultiCompression Levels

```ruby
# Access level constants
puts MultiCompress::Zstd::MIN_LEVEL      # => 1
puts MultiCompress::Zstd::MAX_LEVEL      # => 22  
puts MultiCompress::Zstd::DEFAULT_LEVEL  # => 3

puts MultiCompress::LZ4::MIN_LEVEL       # => 1
puts MultiCompress::LZ4::MAX_LEVEL       # => 16
puts MultiCompress::LZ4::DEFAULT_LEVEL   # => 1

puts MultiCompress::Brotli::MIN_LEVEL    # => 0
puts MultiCompress::Brotli::MAX_LEVEL    # => 11
puts MultiCompress::Brotli::DEFAULT_LEVEL # => 6

# Validate level before compression
def safe_compress(data, algo, level)
  case algo
  when :zstd
    level = level.clamp(MultiCompress::Zstd::MIN_LEVEL, MultiCompress::Zstd::MAX_LEVEL)
  when :lz4
    level = level.clamp(MultiCompress::LZ4::MIN_LEVEL, MultiCompress::LZ4::MAX_LEVEL)
  when :brotli
    level = level.clamp(MultiCompress::Brotli::MIN_LEVEL, MultiCompress::Brotli::MAX_LEVEL)
  end
  
  MultiCompress.compress(data, algo: algo, level: level)
end
```

## Error Handling

### Exception Types

```ruby
begin
  compressed = MultiCompress.compress(data, algo: :zstd, level: 999)
rescue MultiCompress::LevelError => e
  puts "Invalid compression level: #{e.message}"
rescue MultiCompress::Error => e
  puts "General compression error: #{e.message}"
end

# All exception types
MultiCompress::Error              # Base class for all compress errors
MultiCompress::DataError          # Corrupt or invalid compressed data
MultiCompress::MemError           # Out of memory during operation  
MultiCompress::StreamError        # Stream operation error (e.g. write after close)
MultiCompress::UnsupportedError   # Unsupported operation (e.g. dictionary with LZ4)
MultiCompress::LevelError         # Invalid compression level
```

### Robust Error Handling

```ruby
def safe_decompress(compressed_data, fallback: nil)
  MultiCompress.decompress(compressed_data)
rescue MultiCompress::DataError => e
  Rails.logger.warn "Data corruption detected: #{e.message}"
  fallback
rescue MultiCompress::Error => e
  Rails.logger.error "Decompression failed: #{e.message}"
  fallback
end

def safe_compress_with_retry(data, algo: :zstd, level: 3, retries: 2)
  attempt = 0
  
  begin
    MultiCompress.compress(data, algo: algo, level: level)
  rescue MultiCompress::MemError => e
    attempt += 1
    if attempt <= retries
      GC.start  # Try to free memory
      level = [level - 1, 1].max  # Reduce compression level
      retry
    else
      raise
    end
  end
end
```

## Performance Tips

### Choosing MultiCompression Levels

```ruby
# For real-time applications (low latency)
MultiCompress.compress(data, algo: :lz4, level: 1)     # Fastest

# For network transfer (balance speed/size)  
MultiCompress.compress(data, algo: :zstd, level: 3)    # Default balance

# For archival (maximum compression)
MultiCompress.compress(data, algo: :brotli, level: 11) # Best ratio

# For streaming/hot paths
MultiCompress.compress(data, algo: :zstd, level: 1)    # Fast zstd
```

### Memory Management

```ruby
# Process large files in chunks to avoid memory issues
def process_large_file(input_path, output_path)
  deflater = MultiCompress::Deflater.new(algo: :zstd, level: 3)
  
  begin
    File.open(input_path, 'rb') do |input|
      File.open(output_path, 'wb') do |output|
        while chunk = input.read(1024 * 1024)  # 1MB chunks
          compressed = deflater.write(chunk)
          output.write(compressed) unless compressed.empty?
          
          # Explicitly manage memory for very large files
          GC.start if input.tell % (100 * 1024 * 1024) == 0  # Every 100MB
        end
        
        output.write(deflater.finish)
      end
    end
  ensure
    deflater.close  # Always close to free resources
  end
end
```

### Benchmarking Your Data

```ruby
require 'benchmark'

def benchmark_algorithms(data)
  algorithms = [:lz4, :zstd, :brotli]
  results = {}
  
  algorithms.each do |algo|
    time = Benchmark.realtime do
      compressed = MultiCompress.compress(data, algo: algo)
      decompressed = MultiCompress.decompress(compressed)
    end
    
    compressed = MultiCompress.compress(data, algo: algo)
    ratio = compressed.bytesize.to_f / data.bytesize
    
    results[algo] = { 
      time: time.round(4),
      ratio: ratio.round(3),
      size: compressed.bytesize 
    }
  end
  
  results
end

# Test with your specific data
sample_data = File.read("typical_payload.json")
results = benchmark_algorithms(sample_data)
puts results
# => {:lz4=>{:time=>0.0012, :ratio=>0.234, :size=>1024}, ...}
```

This guide covers comprehensive usage of the MultiCompress gem. For advanced use cases or questions, see the source code or create an issue on GitHub.
