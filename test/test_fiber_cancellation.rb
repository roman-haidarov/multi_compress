# frozen_string_literal: true

require_relative "test_helper"

unless defined?(ASYNC_AVAILABLE)
  begin
    require "async"
    ASYNC_AVAILABLE = true
  rescue LoadError
    ASYNC_AVAILABLE = false
  end
end

class TestFiberCancellation < Minitest::Test
  PAYLOAD = begin
    rng = Random.new(123)
    rng.bytes(8 * 1024 * 1024)
  end

  CANCEL_PAYLOAD = (PAYLOAD * 4).freeze

  def setup
    skip "async gem is not installed" unless ASYNC_AVAILABLE
    skip "Skipped under ASAN: CRuby Thread/Fiber runtime issue" if ENV["MULTI_COMPRESS_SKIP_FIBER_SCHEDULER_TESTS"] == "1"
  end

  def stop_async_compress_once(payload = CANCEL_PAYLOAD)
    Async do |task|
      compressor = task.async do
        MultiCompress.compress(payload, algo: :zstd, level: :best)
      end

      Async::Task.current.sleep(0.005)
      compressor.stop
      Async::Task.current.sleep(0.001)
    end
  end

  def test_gc_start_during_async_compress_keeps_roundtrip_working
    [:zstd, :lz4, :brotli].each do |algo|
      compressed = nil

      Async do |task|
        gc_task = task.async do
          10.times do
            GC.start
            Async::Task.current.sleep(0.001)
          end
        end

        compressed = MultiCompress.compress(PAYLOAD, algo: algo)
        gc_task.wait
      end

      assert_equal PAYLOAD, MultiCompress.decompress(compressed, algo: algo),
        "#{algo}: roundtrip failed after GC pressure"
    end
  end

  def test_many_async_compressions_in_sequence_do_not_break_subsequent_calls
    [:zstd, :lz4, :brotli].each do |algo|
      results = []

      Async do
        5.times do |i|
          payload = "#{algo}-#{i}-" + PAYLOAD.byteslice(i * 1024, 256 * 1024)
          results << MultiCompress.compress(payload, algo: algo)
        end
      end

      results.each_with_index do |compressed, i|
        payload = "#{algo}-#{i}-" + PAYLOAD.byteslice(i * 1024, 256 * 1024)
        assert_equal payload, MultiCompress.decompress(compressed, algo: algo),
          "#{algo}: sequential async compression #{i} corrupted output"
      end
    end
  end

  def test_thread_kill_during_async_compress_does_not_break_future_compress
    started = Queue.new

    worker = Thread.new do
      Async do
        started << true
        MultiCompress.compress(PAYLOAD, algo: :zstd)
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
