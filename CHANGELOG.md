# Changelog

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
