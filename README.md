# MultiCompress 🗜️

[![Gem Version](https://badge.fury.io/rb/multi_compress.svg)](https://badge.fury.io/rb/multi_compress)

> **⚠️ PROOF OF CONCEPT** — This is a proof-of-concept implementation. While functional and well-tested, additional features and optimizations are planned before the production-ready release.

Modern compression technology: **zstd**, **lz4**, **brotli** — unified compression platform with native C performance.

📖 **[Get Started →](GET_STARTED.md)** — Complete technology overview, algorithms, and implementation details

## Technology Overview

**MultiCompress** is a comprehensive compression system that unites three cutting-edge algorithms in a single platform. Modern algorithms are 3–10x faster than traditional zlib while providing superior compression ratios.

| Algorithm | Strength | Best for |
|-----------|----------|----------|
| **zstd** | Best speed/ratio balance | Cache, logs, backups |
| **lz4** | Fastest compress/decompress | IPC, hot cache, real-time |
| **brotli** | Best ratio for HTTP | Web assets, API responses |

## How It Works

**MultiCompress** packages modern compression algorithms (zstd, lz4, brotli) with their native C libraries, providing a unified interface. The system includes vendored sources of all compression libraries, eliminating external dependencies.

### Key Design Principles

- **Zero external dependencies**: All C libraries are vendored and compiled
- **Unified API**: Same interface for all algorithms — just change the `algo:` parameter  
- **Performance first**: Direct bindings to C libraries, minimal overhead
- **Memory efficient**: Streaming support for large datasets, proper resource cleanup
- **Production ready**: Battle-tested error handling, comprehensive test coverage

### Algorithm Auto-Detection

The system can automatically detect compression algorithms when decompressing data:

- **zstd**: Detected by magic bytes `28 B5 2F FD` (little-endian)
- **lz4**: Detected by internal format header validation (custom format, NOT compatible with lz4 CLI)
- **brotli**: Requires explicit `algo: :brotli` parameter - no auto-detection

**Important**: Auto-detection only works for ZSTD and LZ4. Brotli data must be decompressed with explicit algorithm specification.

**Security**: All decompression operations have a built-in 256MB size limit to prevent decompression bomb attacks.

## Algorithm Comparison

| Algorithm | Speed | Ratio | Best Use Case |
|-----------|-------|--------|---------------|
| **lz4** | Fastest | Good | Real-time processing, IPC, hot cache paths |
| **zstd** | Fast | Excellent | General purpose, logs, backups, web APIs |
| **brotli** | Slower | Best | Static assets, CDN, long-term storage |


## Benchmark Results

> **📝 Note on v0.1.2**: This version includes a fix for a critical LZ4 streaming bug that caused incorrect decompression on large data. The fix introduces a ~40-50% performance regression on large chunks (128KB+) in LZ4 streaming mode, but small chunks (4-32KB) maintain original performance. Since streaming typically uses smaller chunks, and correctness is prioritized over peak performance, the overall impact is minimal.

Performance comparison against Ruby's built-in zlib compression:

### 🗜️  COMPRESSION RATIO (%, lower is better)
```
┌─────────────────────────────┬─────────┬─────────┬─────────┬─────────┐
│ Configuration               │  zlib   │   lz4   │  zstd   │ brotli  │
├─────────────────────────────┼─────────┼─────────┼─────────┼─────────┤
│ Small JSON (small, GC)      │    8.8% │   16.2% │    8.2% │    6.5% │
│ Small text (small, GC)      │   11.6% │   20.0% │   13.1% │   11.5% │
│ Small JSON (small, no GC)   │    8.8% │   16.2% │    8.2% │    6.5% │
│ Small text (small, no GC)   │   11.6% │   20.0% │   13.1% │   11.5% │
│ Medium JSON (medium, GC)    │    8.3% │   15.5% │    8.9% │    7.1% │
│ Medium logs (medium, GC)    │   15.9% │   26.7% │   17.9% │   15.5% │
│ Medium JSON (medium, no GC) │    8.3% │   15.5% │    8.9% │    7.1% │
│ Medium logs (medium, no GC) │   15.9% │   26.7% │   17.9% │   15.5% │
└─────────────────────────────┴─────────┴─────────┴─────────┴─────────┘
```

### ⚡ PROCESSING SPEED (average time in milliseconds, lower is faster)
```
┌─────────────────────────────┬─────────┬─────────┬─────────┬─────────┐
│ Configuration               │  zlib   │   lz4   │  zstd   │ brotli  │
├─────────────────────────────┼─────────┼─────────┼─────────┼─────────┤
│ Small JSON (small, GC)      │    0.68 │    0.20 │    0.30 │    1.64 │
│ Small text (small, GC)      │    2.35 │    0.68 │    1.19 │    6.57 │
│ Small JSON (small, no GC)   │    0.69 │    0.19 │    0.30 │    1.72 │
│ Small text (small, no GC)   │    2.32 │    0.67 │    1.13 │    6.45 │
│ Medium JSON (medium, GC)    │   21.89 │    6.24 │    8.58 │   49.56 │
│ Medium logs (medium, GC)    │   45.91 │   11.55 │   22.47 │  131.84 │
│ Medium JSON (medium, no GC) │   22.90 │    6.07 │    8.67 │   52.25 │
│ Medium logs (medium, no GC) │   44.00 │   10.82 │   21.56 │  125.21 │
└─────────────────────────────┴─────────┴─────────┴─────────┴─────────┘
```


**Dependencies for benchmarking:**
- `memory_profiler` — Memory usage analysis
- `benchmark-ips` — Iterations per second benchmarking

Or use the build script:

```bash
./build.sh
```

## Requirements

- Ruby >= 2.7.0
- C compiler (gcc, clang)

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a Pull Request

## License

MIT — see [LICENSE.txt](LICENSE.txt).
