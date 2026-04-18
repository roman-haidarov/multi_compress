# frozen_string_literal: true

require_relative "test_helper"
require "timeout"

class TestConcurrentOperations < Minitest::Test
  def setup
    @data = "Hello, World! " * 100
    @large_data = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. " * 1000
    @binary_data = (0..255).to_a.pack("C*") * 10
    @compression_data = "A" * 100_000
  end

  def test_concurrent_dictionary_usage_zstd
    dict_data = "common patterns for zstd compression dictionary test data"
    dict = MultiCompress::Dictionary.new(dict_data, algo: :zstd)

    thread_count = 10
    results = []
    mutex = Mutex.new

    threads = thread_count.times.map do |i|
      Thread.new do
        test_data = "Thread #{i} data: #{@data * (i + 1)}"
        compressed = MultiCompress.compress(test_data, algo: :zstd, dictionary: dict)
        decompressed = MultiCompress.decompress(compressed, algo: :zstd, dictionary: dict)

        mutex.synchronize do
          results << {
            thread_id: i,
            original_size: test_data.bytesize,
            compressed_size: compressed.bytesize,
            success: test_data == decompressed
          }
        end
      end
    end

    Timeout.timeout(10) { threads.each(&:join) }

    assert_equal thread_count, results.size, "All threads should complete"
    assert results.all? { |r| r[:success] }, "All compressions should roundtrip correctly"

    results.each do |result|
      assert result[:compressed_size] < result[:original_size], 
             "Thread #{result[:thread_id]} should compress data"
    end
  end

  def test_concurrent_dictionary_usage_zstd_multiple_levels
    dict_data = (("common patterns for zstd compression dictionary test data " * 32) +
                 ("threaded dictionary cache warmup " * 32)).b
    dict = MultiCompress::Dictionary.new(dict_data, algo: :zstd)

    levels = [1, 3, 5, 7, 9, 11, 13, 15, 17, 19]
    iterations = 3
    results = Queue.new

    threads = levels.map do |level|
      Thread.new do
        iterations.times do |i|
          payload = (("level=#{level} iteration=#{i} " * 512) + @compression_data).b
          compressed = MultiCompress.compress(payload, algo: :zstd, level: level, dictionary: dict)
          decompressed = MultiCompress.decompress(compressed, algo: :zstd, dictionary: dict)
          results << [level, i, payload == decompressed]
        end
      end
    end

    Timeout.timeout(20) { threads.each(&:join) }

    expected = levels.size * iterations
    actual = []
    expected.times { actual << results.pop }

    assert_equal expected, actual.size, "all zstd dictionary cache threads should complete"
    refute actual.any? { |(_, _, ok)| !ok }, "all zstd dictionary cache operations should roundtrip"
  end

  def test_concurrent_dictionary_usage_brotli
    dict_data = "common patterns for brotli compression dictionary test data"
    dict = MultiCompress::Dictionary.new(dict_data, algo: :brotli)

    thread_count = 8
    results = []
    mutex = Mutex.new

    threads = thread_count.times.map do |i|
      Thread.new do
        test_data = "Thread #{i} brotli data: #{@data * (i + 1)}"
        compressed = MultiCompress.compress(test_data, algo: :brotli, dictionary: dict)
        decompressed = MultiCompress.decompress(compressed, algo: :brotli, dictionary: dict)

        mutex.synchronize do
          results << {
            thread_id: i,
            success: test_data == decompressed
          }
        end
      end
    end

    Timeout.timeout(15) { threads.each(&:join) }

    assert_equal thread_count, results.size
    assert results.all? { |r| r[:success] }, "All brotli compressions should work correctly"
  end

  def test_concurrent_compression_all_algorithms
    [:zstd, :lz4, :brotli].each do |algo|
      thread_count = 12
      results = []
      mutex = Mutex.new

      threads = thread_count.times.map do |i|
        Thread.new do
          test_data = "#{algo.upcase} Thread #{i}: #{@large_data}"
          compressed = MultiCompress.compress(test_data, algo: algo)
          decompressed = MultiCompress.decompress(compressed, algo: algo)

          mutex.synchronize do
            results << {
              thread_id: i,
              algo: algo,
              success: test_data == decompressed,
              compressed_ratio: compressed.bytesize.to_f / test_data.bytesize
            }
          end
        end
      end

      Timeout.timeout(20) { threads.each(&:join) }

      assert_equal thread_count, results.size, "#{algo}: All threads should complete"
      assert results.all? { |r| r[:success] }, "#{algo}: All compressions should work"

      avg_ratio = results.sum { |r| r[:compressed_ratio] } / results.size
      assert avg_ratio < 0.5, "#{algo}: Should achieve reasonable compression (avg: #{avg_ratio})"
    end
  end

  def test_concurrent_streaming_operations
    [:zstd, :lz4, :brotli].each do |algo|
      thread_count = 8
      results = []
      mutex = Mutex.new
      threads = thread_count.times.map do |i|
        Thread.new do
          deflater = MultiCompress::Deflater.new(algo: algo)
          inflater = MultiCompress::Inflater.new(algo: algo)
          test_data = "Stream #{i}: #{@data * 20}"
          compressed = +""
          chunk_size = test_data.bytesize / 4
          4.times do |chunk_idx|
            start_idx = chunk_idx * chunk_size
            end_idx = (chunk_idx == 3) ? -1 : (start_idx + chunk_size - 1)
            chunk = test_data[start_idx..end_idx]
            compressed << deflater.write(chunk)
          end
          compressed << deflater.finish
          deflater.close

          decompressed = +""
          compressed_chunk_size = compressed.bytesize / 3
          3.times do |chunk_idx|
            start_idx = chunk_idx * compressed_chunk_size
            end_idx = (chunk_idx == 2) ? -1 : (start_idx + compressed_chunk_size - 1)
            chunk = compressed[start_idx..end_idx]
            decompressed << inflater.write(chunk)
          end
          inflater.finish
          inflater.close

          mutex.synchronize do
            results << {
              thread_id: i,
              algo: algo,
              success: test_data == decompressed
            }
          end
        end
      end

      Timeout.timeout(15) { threads.each(&:join) }

      assert_equal thread_count, results.size, "#{algo}: All streaming threads should complete"
      assert results.all? { |r| r[:success] }, "#{algo}: All streaming operations should work"
    end
  end

  def test_high_concurrency_stress
    thread_count = 50
    operations_per_thread = 20
    total_operations = thread_count * operations_per_thread
    completed_operations = Concurrent::AtomicFixnum.new(0) rescue completed_operations = 0
    mutex = defined?(Concurrent::AtomicFixnum) ? nil : Mutex.new

    threads = thread_count.times.map do |thread_id|
      Thread.new do
        operations_per_thread.times do |op_id|
          algo = [:zstd, :lz4, :brotli].sample
          data = "T#{thread_id}-O#{op_id}: #{@data}"

          compressed = MultiCompress.compress(data, algo: algo)
          decompressed = MultiCompress.decompress(compressed, algo: algo)

          raise "Mismatch in T#{thread_id}-O#{op_id}" unless data == decompressed

          if defined?(Concurrent::AtomicFixnum)
            completed_operations.increment
          else
            mutex.synchronize { completed_operations += 1 }
          end
        end
      end
    end

    Timeout.timeout(30) { threads.each(&:join) }

    final_count = defined?(Concurrent::AtomicFixnum) ? completed_operations.value : completed_operations
    assert_equal total_operations, final_count, "All stress test operations should complete"
  end

  def test_concurrent_large_data_gvl_unlock
    large_test_data = "X" * 200_000
    thread_count = 6
    results = []
    mutex = Mutex.new

    threads = thread_count.times.map do |i|
      Thread.new do
        start_time = Time.now
        compressed = MultiCompress.compress(large_test_data, algo: :zstd)
        decompressed = MultiCompress.decompress(compressed, algo: :zstd)
        end_time = Time.now

        mutex.synchronize do
          results << {
            thread_id: i,
            duration: end_time - start_time,
            success: large_test_data == decompressed,
            original_size: large_test_data.bytesize,
            compressed_size: compressed.bytesize
          }
        end
      end
    end

    Timeout.timeout(25) { threads.each(&:join) }

    assert_equal thread_count, results.size
    assert results.all? { |r| r[:success] }, "All large data operations should succeed"

    avg_duration = results.sum { |r| r[:duration] } / results.size
    max_duration = results.map { |r| r[:duration] }.max

    sequential_time_estimate = results.sum { |r| r[:duration] }

    assert max_duration < sequential_time_estimate * 0.8, 
           "Operations should run in parallel (max: #{max_duration}s, sequential estimate: #{sequential_time_estimate}s)"

    compression_ratios = results.map { |r| r[:compressed_size].to_f / r[:original_size] }
    avg_ratio = compression_ratios.sum / compression_ratios.size
    assert avg_ratio < 0.1, "Large repetitive data should compress very well (ratio: #{avg_ratio})"
  end

  def test_dictionary_integrity_under_load
    dict_data = "common dictionary data " * 100
    dict = MultiCompress::Dictionary.new(dict_data, algo: :zstd)

    original_size = dict.size
    original_algo = dict.algo

    thread_count = 20
    operations_per_thread = 10

    threads = thread_count.times.map do |thread_id|
      Thread.new do
        operations_per_thread.times do |op_id|
          test_data = "Dict integrity test T#{thread_id}-O#{op_id}: #{@data}"

          compressed = MultiCompress.compress(test_data, algo: :zstd, dictionary: dict)
          decompressed = MultiCompress.decompress(compressed, algo: :zstd, dictionary: dict)

          raise "Dictionary integrity failure T#{thread_id}-O#{op_id}" unless test_data == decompressed
        end
      end
    end

    Timeout.timeout(20) { threads.each(&:join) }

    assert_equal original_size, dict.size, "Dictionary size should remain unchanged"
    assert_equal original_algo, dict.algo, "Dictionary algorithm should remain unchanged"

    test_data = "Post-concurrent dictionary test: #{@data}"
    compressed = MultiCompress.compress(test_data, algo: :zstd, dictionary: dict)
    decompressed = MultiCompress.decompress(compressed, algo: :zstd, dictionary: dict)
    assert_equal test_data, decompressed, "Dictionary should still work after concurrent usage"
  end

  def test_dictionary_cache_stress_test
    dict_data = "stress test dictionary patterns " * 50
    dict = MultiCompress::Dictionary.new(dict_data, algo: :zstd)
    thread_count = 30
    operations_per_thread = 50
    total_operations = thread_count * operations_per_thread
    completed_operations = 0
    mutex = Mutex.new
    errors = []

    threads = thread_count.times.map do |thread_id|
      Thread.new do
        operations_per_thread.times do |op_id|
          begin
            level = [1, 3, 6, 9, 15, 19, 22].sample
            test_data = "Stress T#{thread_id}-O#{op_id}: #{@data}"
            compressed = MultiCompress.compress(test_data, algo: :zstd, level: level, dictionary: dict)
            decompressed = MultiCompress.decompress(compressed, algo: :zstd, dictionary: dict)
            raise "Data mismatch T#{thread_id}-O#{op_id}" unless test_data == decompressed

            mutex.synchronize { completed_operations += 1 }
          rescue => e
            mutex.synchronize { errors << "T#{thread_id}-O#{op_id}: #{e.message}" }
          end
        end
      end
    end

    Timeout.timeout(45) { threads.each(&:join) }

    assert_equal [], errors, "No errors should occur during stress test: #{errors.first(5)}"
    assert_equal total_operations, completed_operations, 
                 "All stress operations should complete (completed: #{completed_operations}/#{total_operations})"
  end

  def test_dictionary_memory_pressure
    large_dict_data = "large dictionary pattern " * 1000
    dicts = 3.times.map { |i| 
      MultiCompress::Dictionary.new("#{large_dict_data} #{i}", algo: :zstd) 
    }

    thread_count = 15
    cycles_per_thread = 10
    completed_cycles = 0
    mutex = Mutex.new
    threads = thread_count.times.map do |thread_id|
      Thread.new do
        cycles_per_thread.times do |cycle_id|
          dict = dicts.sample
          test_data = "Memory pressure T#{thread_id}-C#{cycle_id}: #{@large_data[0, 10000]}"
          compressed = MultiCompress.compress(test_data, algo: :zstd, dictionary: dict)
          decompressed = MultiCompress.decompress(compressed, algo: :zstd, dictionary: dict)
          raise "Memory pressure failure T#{thread_id}-C#{cycle_id}" unless test_data == decompressed

          mutex.synchronize { completed_cycles += 1 }
          sleep(0.001) if cycle_id % 5 == 0
        end
      end
    end

    Timeout.timeout(30) { threads.each(&:join) }

    expected_cycles = thread_count * cycles_per_thread
    assert_equal expected_cycles, completed_cycles, 
                 "Memory pressure test should complete all cycles"

    dicts.each_with_index do |dict, i|
      test_data = "Post-pressure dict #{i} test: #{@data}"
      compressed = MultiCompress.compress(test_data, algo: :zstd, dictionary: dict)
      decompressed = MultiCompress.decompress(compressed, algo: :zstd, dictionary: dict)
      assert_equal test_data, decompressed, "Dictionary #{i} should work after memory pressure"
    end
  end

  def test_dictionary_high_concurrency
    dict_data = "high concurrency dictionary test patterns"
    dict = MultiCompress::Dictionary.new(dict_data, algo: :zstd)
    thread_count = 100
    operations_per_thread = 5
    total_operations = thread_count * operations_per_thread
    start_time = Time.now
    completed_operations = 0
    mutex = Mutex.new

    threads = thread_count.times.map do |thread_id|
      Thread.new do
        operations_per_thread.times do |op_id|
          test_data = "HC T#{thread_id}-O#{op_id}: #{@data[0, 500]}"
          compressed = MultiCompress.compress(test_data, algo: :zstd, dictionary: dict)
          decompressed = MultiCompress.decompress(compressed, algo: :zstd, dictionary: dict)
          raise "HC failure T#{thread_id}-O#{op_id}" unless test_data == decompressed

          mutex.synchronize { completed_operations += 1 }
        end
      end
    end

    Timeout.timeout(25) { threads.each(&:join) }
    end_time = Time.now
    duration = end_time - start_time
    throughput = completed_operations / duration

    assert_equal total_operations, completed_operations, 
                 "All high concurrency operations should complete"

    puts "High concurrency test: #{completed_operations} ops in #{duration.round(2)}s (#{throughput.round(1)} ops/s)" if ENV['VERBOSE']

    test_data = "Post high-concurrency test: #{@data}"
    compressed = MultiCompress.compress(test_data, algo: :zstd, dictionary: dict)
    decompressed = MultiCompress.decompress(compressed, algo: :zstd, dictionary: dict)
    assert_equal test_data, decompressed, "Dictionary should work after high concurrency test"
  end

  def test_mixed_concurrent_scenario
    zstd_dict = MultiCompress::Dictionary.new("zstd patterns " * 20, algo: :zstd)
    brotli_dict = MultiCompress::Dictionary.new("brotli patterns " * 20, algo: :brotli)
    thread_count = 12
    operations_per_thread = 15
    results = []
    mutex = Mutex.new
    threads = thread_count.times.map do |thread_id|
      Thread.new do
        operations_per_thread.times do |op_id|
          scenario = [:zstd_dict, :brotli_dict, :no_dict, :large_no_dict].sample

          case scenario
          when :zstd_dict
            test_data = "Mixed ZSTD Dict T#{thread_id}-O#{op_id}: #{@data}"
            compressed = MultiCompress.compress(test_data, algo: :zstd, dictionary: zstd_dict)
            decompressed = MultiCompress.decompress(compressed, algo: :zstd, dictionary: zstd_dict)
          when :brotli_dict
            test_data = "Mixed Brotli Dict T#{thread_id}-O#{op_id}: #{@data}"
            compressed = MultiCompress.compress(test_data, algo: :brotli, dictionary: brotli_dict)
            decompressed = MultiCompress.decompress(compressed, algo: :brotli, dictionary: brotli_dict)
          when :no_dict
            algo = [:zstd, :lz4, :brotli].sample
            test_data = "Mixed No-Dict #{algo} T#{thread_id}-O#{op_id}: #{@data}"
            compressed = MultiCompress.compress(test_data, algo: algo)
            decompressed = MultiCompress.decompress(compressed, algo: algo)
          when :large_no_dict
            algo = [:zstd, :lz4, :brotli].sample
            test_data = "Mixed Large #{algo} T#{thread_id}-O#{op_id}: #{@large_data[0, 20000]}"
            compressed = MultiCompress.compress(test_data, algo: algo)
            decompressed = MultiCompress.decompress(compressed, algo: algo)
          end

          success = test_data == decompressed

          mutex.synchronize do
            results << {
              thread_id: thread_id,
              op_id: op_id,
              scenario: scenario,
              success: success
            }
          end
          raise "Mixed scenario failure T#{thread_id}-O#{op_id} (#{scenario})" unless success
        end
      end
    end

    Timeout.timeout(35) { threads.each(&:join) }

    expected_results = thread_count * operations_per_thread
    assert_equal expected_results, results.size, "All mixed scenario operations should complete"
    assert results.all? { |r| r[:success] }, "All mixed scenarios should succeed"

    scenario_counts = results.group_by { |r| r[:scenario] }.transform_values(&:size)
    puts "Mixed scenario distribution: #{scenario_counts}" if ENV['VERBOSE']

    [:zstd_dict, :brotli_dict, :no_dict, :large_no_dict].each do |scenario|
      assert scenario_counts[scenario] > 0, "Scenario #{scenario} should be tested"
    end
  end
end
