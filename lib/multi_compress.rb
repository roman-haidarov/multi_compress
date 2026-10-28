# frozen_string_literal: true

require "multi_compress/version"

begin
  require "multi_compress/multi_compress"
rescue LoadError
  ext_dir = File.expand_path("multi_compress", __dir__)

  so_path = %w[.bundle .so]
            .map { |ext| File.join(ext_dir, "multi_compress#{ext}") }
            .find { |path| File.exist?(path) }

  raise LoadError, "Could not find compiled MultiCompress extension. Run: bundle exec rake compile" unless so_path

  require so_path
end

module MultiCompress
  FASTEST = :fastest
  DEFAULT = :default
  BEST    = :best

  DEFAULT_MAX_OUTPUT_SIZE = 512 * 1024 * 1024
  DEFAULT_STREAMING_MAX_OUTPUT_SIZE = 2 * 1024 * 1024 * 1024

  EXTENSION_MAP = {
    ".zst" => :zstd,
    ".zstd" => :zstd,
    ".lz4" => :lz4,
    ".br" => :brotli
  }.freeze

  private_constant :EXTENSION_MAP

  class Config
    attr_reader :max_output_size, :streaming_max_output_size

    def initialize
      reset!
    end

    def max_output_size=(value)
      @max_output_size = normalize_limit(value, :max_output_size, DEFAULT_MAX_OUTPUT_SIZE)
    end

    def streaming_max_output_size=(value)
      @streaming_max_output_size = normalize_limit(
        value,
        :streaming_max_output_size,
        DEFAULT_STREAMING_MAX_OUTPUT_SIZE
      )
    end

    def reset!
      @max_output_size = DEFAULT_MAX_OUTPUT_SIZE
      @streaming_max_output_size = DEFAULT_STREAMING_MAX_OUTPUT_SIZE
      self
    end

    def dup
      copy = self.class.new
      copy.max_output_size = max_output_size
      copy.streaming_max_output_size = streaming_max_output_size
      copy
    end

    private

    def normalize_limit(value, name, default)
      return default if value.nil?
      raise TypeError, "#{name} must be an Integer" unless value.respond_to?(:to_int)

      limit = value.to_int
      raise ArgumentError, "#{name} must be greater than 0" if limit <= 0

      limit
    end
  end

  class << self
    def config
      @config ||= Config.new
    end

    def configure
      return config unless block_given?

      yield(config)
      config
    end

    unless private_method_defined?(:_c_decompress)
      alias _c_decompress decompress
      private :_c_decompress
    end

    def zstd(data, level: nil)
      compress(data, algo: :zstd, level: level)
    end

    def lz4(data, level: nil, format: nil)
      if format
        compress(data, algo: :lz4, level: level, format: format)
      else
        compress(data, algo: :lz4, level: level)
      end
    end

    def brotli(data, level: nil)
      compress(data, algo: :brotli, level: level)
    end

    def decompress(data, **opts)
      _c_decompress(data, **resolved_one_shot_options(opts))
    end

    def zstd_decompress(data)
      decompress(data, algo: :zstd)
    end

    def lz4_decompress(data, format: nil)
      if format
        decompress(data, algo: :lz4, format: format)
      else
        decompress(data, algo: :lz4)
      end
    end

    def brotli_decompress(data)
      decompress(data, algo: :brotli)
    end

    def algo_from_ext(path)
      EXTENSION_MAP[File.extname(path).downcase]
    end

    private

    def resolved_one_shot_options(opts)
      return opts.merge(max_output_size: config.max_output_size) unless opts.key?(:max_output_size)

      opts
    end
  end

  module InflaterDefaults
    def initialize(*args, **opts)
      resolved = opts.dup
      resolved[:max_output_size] = MultiCompress.config.streaming_max_output_size unless resolved.key?(:max_output_size)
      super(*args, **resolved)
    end
  end

  Inflater.prepend(InflaterDefaults)

  require "multi_compress/stream_io"
  require "multi_compress/writer"
  require "multi_compress/reader"
end
