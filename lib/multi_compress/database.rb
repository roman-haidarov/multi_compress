# frozen_string_literal: true

require "digest"
require "multi_compress"

module MultiCompress
  # Long-term, SQL-readable envelopes. MCDB1 is dictionary-free. MCDB2 is an
  # opt-in, dictionary-required format for one homogeneous database column.
  module Database
    MAGIC        = "MCDB".b
    VERSION_V1   = 1
    VERSION_V2   = 2
    VERSION      = VERSION_V1 # MCDB1 compatibility alias
    CODEC_ZSTD   = 1
    FLAGS_NONE   = 0
    FLAGS_V1     = FLAGS_NONE
    V1_HEADER_SIZE = 19 # 4 magic + 1 version + 1 codec + 1 flags + 8 size + 4 crc32
    V2_HEADER_SIZE = 27 # MCDB1 header + 8 byte application dictionary_ref
    HEADER_SIZE    = V1_HEADER_SIZE
    ORIGINAL_SIZE_OFFSET = 7
    CRC_OFFSET           = 15
    DICTIONARY_REF_OFFSET = 19
    MAX_OUTPUT = 16 * 1024 * 1024
    MAX_DICTIONARY_BYTES = 256 * 1024
    MAX_DICTIONARY_REF = (2**63) - 1
    MAX_ENVELOPE_V1 = 16_842_771
    MAX_ENVELOPE_V2 = 16_842_779
    MAX_ENVELOPE = MAX_ENVELOPE_V2
    ZSTD_LEVEL   = 6
  end
end

require "multi_compress/database/dictionary"
require "multi_compress/database/operations"
require "multi_compress/database/encoding"
require "multi_compress/database/decoding"
require "multi_compress/database/header"
require "multi_compress/database/validation"

require "multi_compress/database/api"
