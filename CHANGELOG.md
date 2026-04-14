# Changelog

## [0.1.2] — 2026-04-14

### Fixed
- **LZ4 Streaming Correctness**: Fixed critical bug in LZ4 Inflater that caused incorrect decompression on large data (>1MB)
  - Removed complex streaming API (`LZ4_decompress_safe_continue`) that had implementation errors
  - Restored simple, reliable direct decompression (`LZ4_decompress_safe`)
  - All roundtrip tests now pass correctly
- **LZ4 Deflater Ring Buffer**: Fixed ring buffer management to prevent overflow
  - Added proper offset reset when approaching buffer limit
  - Improved memory safety

### Added
- **ZSTD Dictionary Training**: Added `MultiCompress::Zstd.train_dictionary(samples, size:)` method
  - Uses ZDICT API for optimal dictionary generation
  - Allows creating custom dictionaries for better compression on similar data
- **Memory Optimization Helpers**: 
  - Added `rb_binary_str_buf_reserve()` for efficient pre-allocation
  - Added `grow_binary_str()` for safe capacity management

### Changed
- **Memory Efficiency**: Eliminated double-buffering in compress/decompress operations
  - ZSTD, LZ4, Brotli now write directly to Ruby strings when unlocking GVL
  - Reduced memory allocations and improved cache locality
- **Dictionary Support in Streaming**: Fixed dictionary reloading in `reset()` methods
  - Dictionaries are now properly saved as instance variables
  - `deflater.reset` and `inflater.reset` correctly restore dictionary state
- **Brotli Error Handling**: Added comprehensive error checking for dictionary operations
  - All Brotli API calls now verify success/failure
  - More informative error messages

### Performance Notes
- **LZ4 Streaming**: Slight performance regression on large chunks (128KB: ~40-50% slower decompression) 
  - Trade-off for correctness: reliable decompression is prioritized over peak performance
  - Small chunks (4-32KB) maintain original performance
  - Overall impact minimal as streaming typically uses smaller chunks
- **Memory Usage**: Reduced due to elimination of intermediate buffers
- **Dictionary Operations**: Faster on repeated use due to improved caching

### Security
- Improved LZ4 format validation in `detect_algo()`
  - Now checks for proper tail marker (4 zero bytes)
  - Better protection against malformed data

## [0.1.1] — Unreleased

### Breaking Changes
- **REMOVED**: `MultiCompress::Dictionary.train` method - general dictionary training interface removed
- Dictionary training is now algorithm-specific to clarify capabilities

### Added  
- `MultiCompress::Brotli.train_dictionary` - Brotli-specific dictionary training method
- Clear indication that only Brotli supports dictionary training in this implementation

### Changed
- Dictionary training API is now more explicit about which algorithms support it
- Improved API clarity by making training method algorithm-specific

## [0.1.0] — Unreleased

### Added
- One-shot compress/decompress for zstd, lz4, brotli
- Streaming API: Deflater, Inflater
- IO wrappers: Writer, Reader with block-style open
- Dictionary API skeleton (zstd, brotli)
- Auto-detect algorithm by magic bytes and file extension
- Named compression levels: :fastest, :default, :best
- CRC32 / Adler32 utility stubs
- Algorithm info: `.algorithms`, `.available?`, `.version`
