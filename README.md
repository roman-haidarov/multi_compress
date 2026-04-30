# MultiCompress 🗜️

[![Gem Version](https://badge.fury.io/rb/multi_compress.svg)](https://badge.fury.io/rb/multi_compress)

> **Status:** functional, well-tested, and actively evolving. The current release is suitable for real workloads, but the API and implementation details are still being refined in upcoming releases.

Modern compression technology: **zstd**, **lz4**, **brotli** — unified compression platform with native C performance, **fiber-friendly** for modern async Ruby stacks.

Bundled library versions in the current release:
- **zstd 1.5.7**
- **lz4 1.10.0**
- **brotli 1.2.0**

📖 **[Get Started →](GET_STARTED.md)** — Complete technology overview, algorithms, and implementation details

## Technology Overview

**MultiCompress** is a comprehensive compression system that unites three modern algorithms in a single platform. Compared with zlib, results depend on the dataset and algorithm choice: LZ4 is usually chosen for speed, Zstd for balance, and Brotli for ratio.

| Algorithm | Strength | Best for |
|-----------|----------|----------|
| **zstd** | Best speed/ratio balance | Cache, logs, backups |
| **lz4** | Fastest compress/decompress | IPC, hot cache, real-time |
| **brotli** | Best ratio for HTTP | Web assets, API responses |

## How It Works

**MultiCompress** packages modern compression algorithms (zstd, lz4, brotli) with their native C libraries, providing a unified interface. The system includes vendored sources of all compression libraries, eliminating external dependencies.

### Key Design Principles

- **Dictionary support**: Runtime dictionary use is supported for zstd and brotli; Zstd dictionary training is available in the current release line
- **Zero external dependencies**: All C libraries are vendored and compiled
- **Unified API**: Same interface for all algorithms — just change the `algo:` parameter
- **Performance first**: Direct bindings to C libraries, minimal overhead
- **Fiber-friendly**: Compression and decompression cooperate with Ruby's fiber scheduler — safe to use under `async`, `falcon`, or any `Fiber::Scheduler`-based runtime without blocking the event loop. See [GET_STARTED.md](GET_STARTED.md) for details and examples.
- **Memory efficient**: Streaming support for large datasets, proper resource cleanup
- **Operationally focused**: Clear errors, comprehensive tests, and streaming support for practical workloads

### Algorithm Auto-Detection

The system can automatically detect compression algorithms when decompressing data:

- **zstd**: Detected by magic bytes `28 B5 2F FD` (little-endian)
- **lz4**: Detected by internal format header validation (custom internal format, NOT compatible with the standard `lz4` CLI)
- **brotli**: Requires explicit `algo: :brotli` parameter - no auto-detection

**Important**: Auto-detection only works for ZSTD and LZ4. Brotli data must be decompressed with explicit algorithm specification.

**Security**: Decompression now enforces a default 512MB one-shot output cap, a default 2GB cumulative streaming cap, and a 32MB dictionary file size cap.


## Security limits

Decompression-facing APIs now use separate size defaults for one-shot and streaming paths:

- **One-shot default output cap:** `512MB`
- **Streaming cumulative cap:** `2GB` across the lifetime of an `Inflater`/`Reader`
- **Global configuration:** `MultiCompress.configure`
- **Per-call override:** `max_output_size:`
- **Dictionary file size cap:** `32MB` for `MultiCompress::Dictionary.load`

Examples:

```ruby
MultiCompress.configure do |config|
  config.max_output_size = 512 * 1024 * 1024
  config.streaming_max_output_size = 2 * 1024 * 1024 * 1024
end

MultiCompress.decompress(blob, algo: :zstd, max_output_size: 64 * 1024 * 1024)

MultiCompress::Reader.open("archive.zst", max_output_size: 128 * 1024 * 1024) do |reader|
  puts reader.read
end
```

If `max_output_size:` is omitted, one-shot calls use `MultiCompress.config.max_output_size` and streaming calls use `MultiCompress.config.streaming_max_output_size`.

## Algorithm Comparison

| Algorithm | Speed | Ratio | Best Use Case |
|-----------|-------|--------|---------------|
| **lz4** | Fastest | Good | Real-time processing, IPC, hot cache paths |
| **zstd** | Fast | Excellent | General purpose, logs, backups, web APIs |
| **brotli** | Slower | Best | Static assets, CDN, long-term storage |


## Benchmark Results

> Benchmark numbers are environment-dependent. The tables below were generated with **MultiCompress 0.3.2** using vendored **zstd 1.5.7**, **lz4 1.10.0**, and **brotli 1.2.0** on **Ruby 3.1.7 / arm64-darwin24**, 200 iterations per test.
>
> Use these numbers as relative guidance, not absolute guarantees. In this run, **lz4** is consistently the fastest, **zstd** gives the best speed/ratio balance, and **brotli** gives the smallest output size but is not optimized for speed-first paths.

Performance comparison against Ruby's built-in zlib compression:

### 🗜️ Compression ratio (%, lower is better)

| Configuration | zlib | lz4 | zstd | brotli |
|---|---:|---:|---:|---:|
| Small JSON (~10KB, GC) | 9.4% | 16.1% | 6.9% | 6.1% |
| Small text (~10KB, GC) | 3.1% | 4.6% | 3.2% | 2.6% |
| Small JSON (~10KB, no GC) | 9.4% | 16.1% | 6.9% | 6.1% |
| Small text (~10KB, no GC) | 3.1% | 4.6% | 3.2% | 2.6% |
| Medium JSON (~370KB, GC) | 8.5% | 15.7% | 6.6% | 5.4% |
| Medium logs (~168KB, GC) | 8.6% | 17.2% | 5.3% | 3.3% |
| Medium JSON (~370KB, no GC) | 8.5% | 15.7% | 6.6% | 5.4% |
| Medium logs (~168KB, no GC) | 8.6% | 17.2% | 5.3% | 3.3% |
| Large JSON (~1.6MB, GC) | 8.1% | 15.1% | 6.1% | 5.6% |
| Large logs (~600KB, GC) | 7.6% | 16.0% | 2.9% | 2.0% |
| Large JSON (~1.6MB, no GC) | 8.1% | 15.1% | 6.1% | 5.6% |
| Large logs (~600KB, no GC) | 7.6% | 16.0% | 2.9% | 2.0% |

### ⚡ Total time (compress + decompress, ms — lower is faster)

| Configuration | zlib | lz4 | zstd | brotli |
|---|---:|---:|---:|---:|
| Small JSON (~10KB, GC) | 0.05 | 0.01 | 0.02 | 0.14 |
| Small text (~10KB, GC) | 0.04 | 0.00 | 0.01 | 0.12 |
| Small JSON (~10KB, no GC) | 0.05 | 0.01 | 0.02 | 0.14 |
| Small text (~10KB, no GC) | 0.04 | 0.00 | 0.01 | 0.11 |
| Medium JSON (~370KB, GC) | 2.60 | 0.29 | 0.41 | 2.45 |
| Medium logs (~168KB, GC) | 1.28 | 0.13 | 0.17 | 0.96 |
| Medium JSON (~370KB, no GC) | 2.62 | 0.27 | 0.39 | 2.41 |
| Medium logs (~168KB, no GC) | 1.19 | 0.13 | 0.17 | 1.08 |
| Large JSON (~1.6MB, GC) | 11.60 | 1.30 | 1.81 | 11.12 |
| Large logs (~600KB, GC) | 4.11 | 0.41 | 0.46 | 2.99 |
| Large JSON (~1.6MB, no GC) | 11.26 | 1.24 | 1.77 | 10.77 |
| Large logs (~600KB, no GC) | 4.01 | 0.42 | 0.45 | 2.90 |

### 📊 Speedup vs zlib by total time (higher is better)

| Configuration | zlib | lz4 | zstd | brotli |
|---|---:|---:|---:|---:|
| Small JSON (~10KB, GC) | 1.00x | 5.00x | 2.50x | 0.36x |
| Small text (~10KB, GC) | 1.00x | N/A | 4.00x | 0.33x |
| Small JSON (~10KB, no GC) | 1.00x | 5.00x | 2.50x | 0.36x |
| Small text (~10KB, no GC) | 1.00x | N/A | 4.00x | 0.36x |
| Medium JSON (~370KB, GC) | 1.00x | 8.97x | 6.34x | 1.06x |
| Medium logs (~168KB, GC) | 1.00x | 9.85x | 7.53x | 1.33x |
| Medium JSON (~370KB, no GC) | 1.00x | 9.70x | 6.72x | 1.09x |
| Medium logs (~168KB, no GC) | 1.00x | 9.15x | 7.00x | 1.10x |
| Large JSON (~1.6MB, GC) | 1.00x | 8.92x | 6.41x | 1.04x |
| Large logs (~600KB, GC) | 1.00x | 10.02x | 8.93x | 1.37x |
| Large JSON (~1.6MB, no GC) | 1.00x | 9.08x | 6.36x | 1.05x |
| Large logs (~600KB, no GC) | 1.00x | 9.55x | 8.91x | 1.38x |

### 📏 Compressed size (bytes, lower is better)

| Configuration | zlib | lz4 | zstd | brotli |
|---|---:|---:|---:|---:|
| Small JSON (~10KB, GC) | 900 | 1544 | 665 | 583 |
| Small text (~10KB, GC) | 310 | 461 | 322 | 256 |
| Small JSON (~10KB, no GC) | 900 | 1544 | 665 | 583 |
| Small text (~10KB, no GC) | 310 | 461 | 322 | 256 |
| Medium JSON (~370KB, GC) | 31524 | 57986 | 24557 | 20122 |
| Medium logs (~168KB, GC) | 14488 | 28950 | 8985 | 5549 |
| Medium JSON (~370KB, no GC) | 31524 | 57986 | 24557 | 20122 |
| Medium logs (~168KB, no GC) | 14488 | 28950 | 8985 | 5549 |
| Large JSON (~1.6MB, GC) | 133275 | 250026 | 100965 | 92591 |
| Large logs (~600KB, GC) | 45432 | 96130 | 17385 | 12250 |
| Large JSON (~1.6MB, no GC) | 133275 | 250026 | 100965 | 92591 |
| Large logs (~600KB, no GC) | 45432 | 96130 | 17385 | 12250 |

**Dependencies for benchmarking:**
- `memory_profiler` — Memory usage analysis
- `benchmark-ips` — Iterations per second benchmarking

Or use the build script:

```bash
./build.sh
```

## Requirements

- Ruby >= 3.1.0
- C compiler (gcc, clang)

## License

MIT — see [LICENSE.txt](LICENSE.txt).
