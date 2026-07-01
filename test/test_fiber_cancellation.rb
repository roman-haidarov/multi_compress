# frozen_string_literal: true

require_relative "test_helper"

class TestFiberCancellation < Minitest::Test
  def setup
    skip "requires Async and Fiber::Scheduler" unless MultiCompressTestSupport.async_available?
    skip "Skipped under ASAN: CRuby Thread/Fiber runtime issue" if ENV["MULTI_COMPRESS_SKIP_FIBER_SCHEDULER_TESTS"] == "1"
  end

  def payload
    @payload ||= Random.new(123).bytes(8 * 1024 * 1024)
  end

  def cancel_payload
    @cancel_payload ||= (payload * 4).freeze
  end

  def stop_async_compress_once(data = nil)
    data ||= cancel_payload

    Async do |task|
      compressor = task.async do
        MultiCompress.compress(data, algo: :zstd, level: :best)
      end

      Async::Task.current.sleep(0.005)
      compressor.stop
      Async::Task.current.sleep(0.001)
    end
  end

  def test_gc_start_during_async_compress_keeps_roundtrip_working
    [:zstd, :lz4, :brotli].each do |algo|
      compressed = nil
      data = payload

      Async do |task|
        gc_task = task.async do
          10.times do
            GC.start
            Async::Task.current.sleep(0.001)
          end
        end

        compressed = MultiCompress.compress(data, algo: algo)
        gc_task.wait
      end

      assert_equal data, MultiCompress.decompress(compressed, algo: algo),
        "#{algo}: roundtrip failed after GC pressure"
    end
  end

  def test_many_async_compressions_in_sequence_do_not_break_subsequent_calls
    [:zstd, :lz4, :brotli].each do |algo|
      results = []
      data = payload

      Async do
        5.times do |i|
          chunk = "#{algo}-#{i}-" + data.byteslice(i * 1024, 256 * 1024)
          results << MultiCompress.compress(chunk, algo: algo)
        end
      end

      results.each_with_index do |compressed, i|
        chunk = "#{algo}-#{i}-" + data.byteslice(i * 1024, 256 * 1024)
        assert_equal chunk, MultiCompress.decompress(compressed, algo: algo),
          "#{algo}: sequential async compression #{i} corrupted output"
      end
    end
  end

  def test_thread_kill_during_async_compress_does_not_break_future_compress
    started = Queue.new
    data = payload

    worker = Thread.new do
      Async do
        started << true
        MultiCompress.compress(data, algo: :zstd)
      end
    end

    started.pop
    sleep 0.01
    worker.kill
    worker.join

    GC.start

    sample = ("after-cancel-" * 50_000).b
    compressed = nil

    Async do
      compressed = MultiCompress.compress(sample, algo: :zstd)
    end

    assert_equal sample, MultiCompress.decompress(compressed, algo: :zstd)
  end

  def test_task_stop_during_async_compress_does_not_break_future_compress_or_leave_thread_growth
    baseline_threads = Thread.list.size

    3.times do
      stop_async_compress_once
    end

    GC.start
    settled = false
    20.times do
      if Thread.list.size <= baseline_threads + 2
        settled = true
        break
      end
      sleep 0.01
    end

    assert settled || Thread.list.size <= baseline_threads + 2,
      "task.stop should not leave runaway worker thread growth"

    sample = ("after-task-stop-" * 50_000).b
    compressed = nil

    Async do
      compressed = MultiCompress.compress(sample, algo: :zstd)
    end

    assert_equal sample, MultiCompress.decompress(compressed, algo: :zstd)
  end
end
