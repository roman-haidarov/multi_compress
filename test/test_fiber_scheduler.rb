# frozen_string_literal: true

require_relative "test_helper"

class TestAsyncFiberScheduler < Minitest::Test
  CHUNK_SIZE = 128 * 1024
  TICKER_INTERVAL = 0.0005
  MIN_PROGRESS = 3

  def setup
    skip "requires Async and Fiber::Scheduler" unless MultiCompressTestSupport.async_available?
    skip "Skipped under ASAN: CRuby Thread/Fiber runtime issue" if ENV["MULTI_COMPRESS_SKIP_FIBER_SCHEDULER_TESTS"] == "1"
  end

  def large_data
    @large_data ||= Random.new(42).bytes(50 * 1024 * 1024)
  end

  def start_ticker(task, interval: TICKER_INTERVAL)
    counter = [0]

    ticker = task.async do
      loop do
        counter[0] += 1
        Async::Task.current.sleep(interval)
      end
    end

    [-> { counter[0] }, -> { ticker.stop }]
  end

  [:zstd, :lz4, :brotli].each do |algo|
    define_method("test_oneshot_compress_allows_scheduler_progress_#{algo}") do
      run_oneshot_test(algo)
    end

    define_method("test_streaming_compress_allows_scheduler_progress_#{algo}") do
      run_streaming_test(algo)
    end
  end

  def run_oneshot_test(algo)
    get_count = nil
    stop = nil
    compressed = nil
    before_count = nil
    after_count = nil
    duration = nil
    data = large_data

    Async do |task|
      get_count, stop = start_ticker(task)

      Async::Task.current.sleep(0.05)

      before_count = get_count.call
      t0 = Time.now
      compressed = MultiCompress.compress(data, algo: algo)
      duration = Time.now - t0
      after_count = get_count.call

      stop.call
    end

    assert compressed && compressed.bytesize > 0, "[#{algo}] compressed must not be empty"
    assert_equal data, MultiCompress.decompress(compressed, algo: algo),
      "[#{algo}] roundtrip must match"

    progress = after_count - before_count
    duration_ms = (duration * 1000).round(2)

    assert progress >= MIN_PROGRESS,
      "[#{algo}] scheduler made no progress during one-shot compress " \
      "(duration: #{duration_ms}ms, ticker progress: #{progress}, " \
      "before: #{before_count}, after: #{after_count})"
  end

  def run_streaming_test(algo)
    get_count = nil
    stop = nil
    result = nil
    before_count = nil
    after_count = nil
    duration = nil
    data = large_data

    Async do |task|
      get_count, stop = start_ticker(task)

      Async::Task.current.sleep(0.05)

      deflater = MultiCompress::Deflater.new(algo: algo)
      compressed = +""

      before_count = get_count.call
      t0 = Time.now
      pos = 0
      while pos < data.bytesize
        compressed << deflater.write(data.byteslice(pos, CHUNK_SIZE))
        pos += CHUNK_SIZE
      end
      compressed << deflater.finish
      duration = Time.now - t0
      after_count = get_count.call

      deflater.close
      result = compressed
      stop.call
    end

    assert result && result.bytesize > 0, "[#{algo}] streaming output must not be empty"
    assert_equal data, MultiCompress.decompress(result, algo: algo),
      "[#{algo}] streaming roundtrip must match"

    progress = after_count - before_count
    duration_ms = (duration * 1000).round(2)

    assert progress >= MIN_PROGRESS,
      "[#{algo}] scheduler made no progress during streaming " \
      "(duration: #{duration_ms}ms, ticker progress: #{progress}, " \
      "before: #{before_count}, after: #{after_count})"
  end

  def test_correctness_under_async
    results = nil

    Async do
      tasks = [:zstd, :lz4, :brotli].map do |algo|
        Async do
          data = "#{algo} test: #{"B" * 50_000}"
          compressed = MultiCompress.compress(data, algo: algo)
          decompressed = MultiCompress.decompress(compressed, algo: algo)
          {
            algo: algo,
            ok: data == decompressed,
            comp_size: compressed.bytesize,
            orig_size: data.bytesize,
          }
        end
      end
      results = tasks.map(&:wait)
    end

    assert_equal 3, results.size

    results.each do |result|
      assert result[:ok], "#{result[:algo]}: data mismatch"
      assert result[:comp_size] > 0
      assert result[:comp_size] < result[:orig_size]
    end
  end
end
