# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "open3"
require "multi_compress"

class TestCLI < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXE  = File.join(ROOT, "exe", "multi_compress")
  LIB  = File.join(ROOT, "lib")

  def run_cli(*args, stdin_data: nil)
    env = { "RUBYLIB" => LIB }
    Open3.capture3(env, "ruby", EXE, *args, stdin_data: stdin_data || "")
  end

  def with_tmpdir
    Dir.mktmpdir { |dir| yield dir }
  end

  def test_roundtrip_file
    with_tmpdir do |dir|
      src = File.join(dir, "data.txt")
      File.write(src, "hello compression " * 500)
      _o, _e, st = run_cli("-k", src)
      assert_equal 0, st.exitstatus
      assert File.exist?("#{src}.zst")

      out, _e, st = run_cli("-dc", "#{src}.zst")
      assert_equal 0, st.exitstatus
      assert_equal File.read(src), out
    end
  end

  def test_same_input_output_is_refused_and_source_intact
    with_tmpdir do |dir|
      src = File.join(dir, "original.txt")
      content = "important content\n" * 100
      File.write(src, content)
      _o, err, st = run_cli("-f", "-o", src, src)
      refute_equal 0, st.exitstatus
      assert_match(/same file/, err)
      assert_equal content, File.read(src), "source must be untouched"
    end
  end

  def test_multiple_inputs_with_single_output_refused
    with_tmpdir do |dir|
      a = File.join(dir, "a.txt")
      b = File.join(dir, "b.txt")
      File.write(a, "aaaa\n" * 50)
      File.write(b, "bbbb\n" * 50)
      _o, err, st = run_cli("-f", "-o", File.join(dir, "c.zst"), a, b)
      refute_equal 0, st.exitstatus
      assert_match(/multiple input/, err)
      assert File.exist?(a), "sources must remain"
      assert File.exist?(b), "sources must remain"
    end
  end

  def test_error_leaves_no_partial_output_and_keeps_source
    with_tmpdir do |dir|
      src = File.join(dir, "f.txt")
      File.write(src, "data" * 100)
      _o, _e, st = run_cli("-a", "zstd", "-l", "999", src)
      refute_equal 0, st.exitstatus
      refute File.exist?("#{src}.zst"), "no partial output"
      assert File.exist?(src), "source intact"
    end
  end

  def test_optionparser_error_is_clean_no_backtrace
    with_tmpdir do |dir|
      src = File.join(dir, "f.txt")
      File.write(src, "x")
      _o, err, st = run_cli("-a", "nope", src)
      refute_equal 0, st.exitstatus
      refute_match(/\.rb:\d+:in/, err, "must not print a Ruby backtrace")
    end
  end

  def test_lz4_uses_mclz4_extension_not_lz4
    with_tmpdir do |dir|
      src = File.join(dir, "f.txt")
      File.write(src, "lz4 payload " * 200)
      _o, _e, st = run_cli("-a", "lz4", "-k", src)
      assert_equal 0, st.exitstatus
      assert File.exist?("#{src}.mclz4")
      refute File.exist?("#{src}.lz4"), "must not create a misleading .lz4"
    end
  end


  def test_zero_max_output_is_usage_error
    with_tmpdir do |dir|
      src = File.join(dir, "f.zst")
      File.binwrite(src, MultiCompress.compress("hello", algo: :zstd))
      _o, err, st = run_cli("-d", "-c", "--max-output", "0", src)
      assert_equal 2, st.exitstatus
      assert_match(/must be greater than zero/, err)
      refute_match(/\.rb:\d+:in/, err)
    end
  end

  def test_oversized_max_output_is_clean_error_no_backtrace
    with_tmpdir do |dir|
      src = File.join(dir, "f.zst")
      File.binwrite(src, MultiCompress.compress("hello " * 100, algo: :zstd))
      huge = "9" * 40 + "G"
      _o, err, st = run_cli("-d", "-c", "--max-output", huge, src)
      refute_equal 0, st.exitstatus
      refute_match(/RangeError|\.rb:\d+:in/, err, "must not leak a RangeError backtrace")
      assert_match(/max-output too large/, err)
    end
  end

  def test_directory_input_is_clean_error_no_backtrace
    with_tmpdir do |dir|
      sub = File.join(dir, "subdir")
      Dir.mkdir(sub)
      _o, err, st = run_cli(sub)
      refute_equal 0, st.exitstatus
      refute_match(/\.rb:\d+:in/, err, "must not print a Ruby backtrace")
      assert_match(/multi_compress:/, err)
    end
  end

  def test_pipe_roundtrip
    data = "streamed content " * 300
    compressed, _e, st = run_cli("-a", "zstd", "-c", stdin_data: data)
    assert_equal 0, st.exitstatus
    out, _e, st = run_cli("-d", "-a", "zstd", "-c", stdin_data: compressed)
    assert_equal 0, st.exitstatus
    assert_equal data, out
  end
end
