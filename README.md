# MultiCompress 🗜️

[![Gem Version](https://badge.fury.io/rb/multi_compress.svg)](https://badge.fury.io/rb/multi_compress)

> **⚠️ PROOF OF CONCEPT** — This is a proof-of-concept implementation. While functional and well-tested, additional features and optimizations are planned before the production-ready release.

Modern compression technology: **zstd**, **lz4**, **brotli** — unified compression platform with native C performance, **fiber-friendly** for modern async Ruby stacks.

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
- **Fiber-friendly**: Compression and decompression cooperate with Ruby's fiber scheduler — safe to use under `async`, `falcon`, or any `Fiber::Scheduler`-based runtime without blocking the event loop. See [GET_STARTED.md](GET_STARTED.md) for details and examples.
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

> **📝 Note on v0.2.0**: Performance numbers below are from the v0.2.0 build with fiber-friendly paths enabled. There is no throughput regression compared to v0.1.2 — the fiber-friendly path is only taken when a `Fiber::Scheduler` is active, and even then the worker-thread overhead is negligible for payloads large enough to benefit.

Performance comparison against Ruby's built-in zlib compression (200 iterations per test):

### 🗜️  COMPRESSION RATIO (%, lower is better)
```
┌─────────────────────────────┬─────────┬─────────┬─────────┬─────────┐
│ Configuration               │  zlib   │   lz4   │  zstd   │ brotli  │
├─────────────────────────────┼─────────┼─────────┼─────────┼─────────┤
│ Small JSON (~10KB, GC)      │    9.4% │   16.1% │    6.9% │    6.1% │
│ Small text (~10KB, GC)      │    3.1% │    4.6% │    3.2% │    2.6% │
│ Small JSON (~10KB, no GC)   │    9.4% │   16.1% │    6.9% │    6.1% │
│ Small text (~10KB, no GC)   │    3.1% │    4.6% │    3.2% │    2.6% │
│ Medium JSON (~370KB, GC)    │    8.5% │   15.7% │    6.7% │    5.5% │
│ Medium logs (~168KB, GC)    │    8.6% │   17.2% │    5.4% │    3.2% │
│ Medium JSON (~370KB, no GC) │    8.5% │   15.7% │    6.7% │    5.5% │
│ Medium logs (~168KB, no GC) │    8.6% │   17.2% │    5.4% │    3.2% │
│ Large JSON (~1.6MB, GC)     │    8.1% │   15.1% │    6.1% │    5.6% │
│ Large logs (~600KB, GC)     │    7.6% │   16.0% │    2.8% │    2.1% │
│ Large JSON (~1.6MB, no GC)  │    8.1% │   15.1% │    6.1% │    5.6% │
│ Large logs (~600KB, no GC)  │    7.6% │   16.0% │    2.8% │    2.1% │
└─────────────────────────────┴─────────┴─────────┴─────────┴─────────┘
```

### ⚡ TOTAL TIME (compress + decompress, ms — lower is faster)
```
┌─────────────────────────────┬─────────┬─────────┬─────────┬─────────┐
│ Configuration               │  zlib   │   lz4   │  zstd   │ brotli  │
├─────────────────────────────┼─────────┼─────────┼─────────┼─────────┤
│ Small JSON (~10KB, GC)      │    0.05 │    0.01 │    0.02 │    0.14 │
│ Small text (~10KB, GC)      │    0.04 │    0.00 │    0.01 │    0.11 │
│ Small JSON (~10KB, no GC)   │    0.06 │    0.01 │    0.02 │    0.13 │
│ Small text (~10KB, no GC)   │    0.04 │    0.00 │    0.01 │    0.11 │
│ Medium JSON (~370KB, GC)    │    2.73 │    0.29 │    0.42 │    2.36 │
│ Medium logs (~168KB, GC)    │    1.23 │    0.14 │    0.18 │    0.92 │
│ Medium JSON (~370KB, no GC) │    2.72 │    0.28 │    0.41 │    2.41 │
│ Medium logs (~168KB, no GC) │    1.26 │    0.13 │    0.18 │    0.96 │
│ Large JSON (~1.6MB, GC)     │   12.44 │    1.38 │    1.96 │   12.44 │
│ Large logs (~600KB, GC)     │    4.29 │    0.46 │    0.49 │    2.85 │
│ Large JSON (~1.6MB, no GC)  │   12.22 │    1.28 │    1.86 │   11.83 │
│ Large logs (~600KB, no GC)  │    4.39 │    0.42 │    0.44 │    2.86 │
└─────────────────────────────┴─────────┴─────────┴─────────┴─────────┘
```

### 📊 SPEEDUP vs ZLIB (higher is better)
```
┌─────────────────────────────┬─────────┬─────────┬─────────┬─────────┐
│ Configuration               │  zlib   │   lz4   │  zstd   │ brotli  │
├─────────────────────────────┼─────────┼─────────┼─────────┼─────────┤
│ Small JSON (~10KB, GC)      │   1.00x │   5.00x │   2.50x │   0.36x │
│ Small text (~10KB, GC)      │   1.00x │     N/A │   4.00x │   0.36x │
│ Small JSON (~10KB, no GC)   │   1.00x │   6.00x │   3.00x │   0.46x │
│ Small text (~10KB, no GC)   │   1.00x │     N/A │   4.00x │   0.36x │
│ Medium JSON (~370KB, GC)    │   1.00x │   9.41x │   6.50x │   1.16x │
│ Medium logs (~168KB, GC)    │   1.00x │   8.79x │   6.83x │   1.34x │
│ Medium JSON (~370KB, no GC) │   1.00x │   9.71x │   6.63x │   1.13x │
│ Medium logs (~168KB, no GC) │   1.00x │   9.69x │   7.00x │   1.31x │
│ Large JSON (~1.6MB, GC)     │   1.00x │   9.01x │   6.35x │   1.00x │
│ Large logs (~600KB, GC)     │   1.00x │   9.33x │   8.76x │   1.51x │
│ Large JSON (~1.6MB, no GC)  │   1.00x │   9.55x │   6.57x │   1.03x │
│ Large logs (~600KB, no GC)  │   1.00x │  10.45x │   9.98x │   1.53x │
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

- Ruby >= 2.7.0 (Ruby >= 3.1 required for fiber-friendly execution — earlier versions fall back to regular GVL-unlocking paths)
- C compiler (gcc, clang)

## Contributing

1. Fork it
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes (`git commit -am 'Add feature'`)
4. Push to the branch (`git push origin feature/my-feature`)
5. Create a Pull Request

## License

MIT — see [LICENSE.txt](LICENSE.txt).
