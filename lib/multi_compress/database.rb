# frozen_string_literal: true

require "multi_compress"

module MultiCompress
  module Database
    MAGIC        = "MCDB".b
    VERSION      = 1
    CODEC_ZSTD   = 1
    FLAGS_V1     = 0
    HEADER_SIZE  = 19                    # 4 magic +1 ver +1 codec +1 flags +8 size +4 crc32
    MAX_OUTPUT   = 16 * 1024 * 1024      # 16 MiB decompressed, enforced on write and read
    MAX_ENVELOPE = 16_842_771
    ZSTD_LEVEL   = 6

    module_function

    def compress(text)
      raise TypeError, "MultiCompress::Database.compress expects a String, got #{text.class}" unless text.is_a?(String)

      bytes = utf8_bytes(text)
      n = bytes.bytesize
      if n > MAX_OUTPUT
        raise ArgumentError, "MultiCompress::Database: input is #{n} bytes, over the #{MAX_OUTPUT}-byte v1 limit"
      end

      frame = MultiCompress.compress(bytes, algo: :zstd, level: ZSTD_LEVEL)
      validate_canonical_zstd_frame!(frame, n)

      envelope = header(n, MultiCompress.crc32(bytes)) << frame
      if envelope.bytesize > MAX_ENVELOPE
        raise MultiCompress::DataError,
              "MultiCompress::Database: stored envelope is #{envelope.bytesize} bytes, over the #{MAX_ENVELOPE}-byte v1 limit"
      end

      envelope
    end

    def decompress(blob)
      raise TypeError, "MultiCompress::Database.decompress expects a String, got #{blob.class}" unless blob.is_a?(String)

      b = blob.b
      err("truncated envelope (#{b.bytesize} < #{HEADER_SIZE} bytes)") if b.bytesize < HEADER_SIZE
      err("stored envelope too large (#{b.bytesize} > #{MAX_ENVELOPE} bytes)") if b.bytesize > MAX_ENVELOPE
      err("bad magic")                unless b.byteslice(0, 4) == MAGIC
      err("unsupported version #{b.getbyte(4)}") unless b.getbyte(4) == VERSION
      err("unsupported codec #{b.getbyte(5)}")   unless b.getbyte(5) == CODEC_ZSTD
      err("reserved flags must be 0, got #{b.getbyte(6)}") unless b.getbyte(6) == FLAGS_V1

      original_size = b.byteslice(7, 8).unpack1("Q<")
      err("declared size #{original_size} over the #{MAX_OUTPUT}-byte v1 limit") if original_size > MAX_OUTPUT
      expected_crc = b.byteslice(15, 4).unpack1("L<")

      frame = b.byteslice(HEADER_SIZE, b.bytesize - HEADER_SIZE) || +"".b
      validate_canonical_zstd_frame!(frame, original_size)
      out = MultiCompress.decompress(frame, algo: :zstd, max_output_size: MAX_OUTPUT)
      if out.bytesize != original_size
        err("size mismatch: header says #{original_size}, got #{out.bytesize}")
      end
      actual_crc = MultiCompress.crc32(out)
      err("crc32 mismatch: header #{expected_crc}, computed #{actual_crc}") if actual_crc != expected_crc

      s = out.force_encoding(Encoding::UTF_8)
      err("decompressed bytes are not valid UTF-8") unless s.valid_encoding?
      err("decompressed text contains a NUL byte") if s.include?("\0")
      s
    end

    def valid?(blob)
      decompress(blob)
      true
    rescue StandardError
      false
    end

    def version_string
      "MCDB1 (zstd #{MultiCompress.version(:zstd)})"
    end

    def utf8_bytes(text)
      s = text.encoding == Encoding::UTF_8 ? text : text.dup.force_encoding(Encoding::UTF_8)
      raise ArgumentError, "MultiCompress::Database: input is not valid UTF-8" unless s.valid_encoding?
      raise ArgumentError, "MultiCompress::Database: input contains a NUL byte" if s.include?("\0")

      s.b
    end

    def validate_canonical_zstd_frame!(frame, expected_size)
      _frame_size, content_size = MultiCompress.zstd_single_frame_info(frame)
      err("zstd frame content size #{content_size} does not match header size #{expected_size}") if content_size != expected_size
    rescue MultiCompress::DataError => e
      err(e.message.sub(/\AMultiCompress::Database: /, ""))
    end

    def header(original_size, crc32)
      (MAGIC + [VERSION, CODEC_ZSTD, FLAGS_V1].pack("C3") +
        [original_size].pack("Q<") + [crc32].pack("L<")).b
    end

    def err(message)
      raise MultiCompress::DataError, "MultiCompress::Database: #{message}"
    end

    private_class_method :utf8_bytes, :validate_canonical_zstd_frame!, :header, :err
  end
end
