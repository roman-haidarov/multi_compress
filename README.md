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
│ Small JSON (~10KB, GC)      │    9.4% │   16.1% │    6.9% │    6.1% │
│ Small text (~10KB, GC)      │    3.1% │    4.6% │    3.2% │    2.6% │
│ Small JSON (~10KB, no GC)   │    9.4% │   16.1% │    6.9% │    6.1% │
│ Small text (~10KB, no GC)   │    3.1% │    4.6% │    3.2% │    2.6% │
│ Medium JSON (~370KB, GC)    │    8.5% │   15.7% │    6.7% │    5.4% │
│ Medium logs (~168KB, GC)    │    8.6% │   17.2% │    5.3% │    3.2% │
│ Medium JSON (~370KB, no GC) │    8.5% │   15.7% │    6.7% │    5.4% │
│ Medium logs (~168KB, no GC) │    8.6% │   17.2% │    5.3% │    3.2% │
│ Large JSON (~1.6MB, GC)     │    8.1% │   15.1% │    6.1% │    5.6% │
│ Large logs (~600KB, GC)     │    7.6% │   16.0% │    3.0% │    1.9% │
│ Large JSON (~1.6MB, no GC)  │    8.1% │   15.1% │    6.1% │    5.6% │
│ Large logs (~600KB, no GC)  │    7.6% │   16.0% │    3.0% │    1.9% │
└─────────────────────────────┴─────────┴─────────┴─────────┴─────────┘
```

### ⚡ PROCESSING SPEED (total time in milliseconds, lower is faster)
```
┌─────────────────────────────┬─────────┬─────────┬─────────┬─────────┐
│ Configuration               │  zlib   │   lz4   │  zstd   │ brotli  │
├─────────────────────────────┼─────────┼─────────┼─────────┼─────────┤
│ Small JSON (~10KB, GC)      │    0.05 │    0.01 │    0.02 │    0.14 │
│ Small text (~10KB, GC)      │    0.03 │    0.00 │    0.01 │    0.11 │
│ Small JSON (~10KB, no GC)   │    0.06 │    0.01 │    0.02 │    0.14 │
│ Small text (~10KB, no GC)   │    0.04 │    0.00 │    0.01 │    0.11 │
│ Medium JSON (~370KB, GC)    │    2.84 │    0.30 │    0.45 │    2.63 │
│ Medium logs (~168KB, GC)    │    1.32 │    0.14 │    0.22 │    1.00 │
│ Medium JSON (~370KB, no GC) │    2.78 │    0.27 │    0.43 │    2.54 │
│ Medium logs (~168KB, no GC) │    1.19 │    0.13 │    0.19 │    0.93 │
│ Large JSON (~1.6MB, GC)     │   12.24 │    1.40 │    1.98 │   12.57 │
│ Large logs (~600KB, GC)     │    4.30 │    0.45 │    0.55 │    2.53 │
│ Large JSON (~1.6MB, no GC)  │   11.86 │    1.25 │    1.87 │   11.91 │
│ Large logs (~600KB, no GC)  │    4.32 │    0.42 │    0.45 │    2.56 │
└─────────────────────────────┴─────────┴─────────┴─────────┴─────────┘
```

### 📊 SPEEDUP vs ZLIB (higher is better)
```
┌─────────────────────────────┬─────────┬─────────┬─────────┬─────────┐
│ Configuration               │  zlib   │   lz4   │  zstd   │ brotli  │
├─────────────────────────────┼─────────┼─────────┼─────────┼─────────┤
│ Small JSON (~10KB, GC)      │   1.00x │   5.00x │   2.50x │   0.36x │
│ Small text (~10KB, GC)      │   1.00x │     N/A │   3.00x │   0.27x │
│ Small JSON (~10KB, no GC)   │   1.00x │   6.00x │   3.00x │   0.43x │
│ Small text (~10KB, no GC)   │   1.00x │     N/A │   4.00x │   0.36x │
│ Medium JSON (~370KB, GC)    │   1.00x │   9.47x │   6.31x │   1.08x │
│ Medium logs (~168KB, GC)    │   1.00x │   9.43x │   6.00x │   1.32x │
│ Medium JSON (~370KB, no GC) │   1.00x │  10.30x │   6.47x │   1.09x │
│ Medium logs (~168KB, no GC) │   1.00x │   9.15x │   6.26x │   1.28x │
│ Large JSON (~1.6MB, GC)     │   1.00x │   8.74x │   6.18x │   0.97x │
│ Large logs (~600KB, GC)     │   1.00x │   9.56x │   7.82x │   1.70x │
│ Large JSON (~1.6MB, no GC)  │   1.00x │   9.49x │   6.34x │   1.00x │
│ Large logs (~600KB, no GC)  │   1.00x │  10.29x │   9.60x │   1.69x │
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
