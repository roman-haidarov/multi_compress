# Changelog

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
