# Changelog

## [0.3.4]

### Changed
- Improved one-shot Zstd performance by reusing per-thread CCtx/DCtx.
- On deterministic arm64-darwin benchmarks, total zstd roundtrip improved by ~11–19% on ~10KB payloads,
  ~1–4% on medium payloads, and ~2–6% on log-like large payloads, with identical compressed sizes.

## [0.3.3]

### Changed
- Updated vendored native libraries to **zstd 1.5.7** and **brotli 1.2.0**.
- Updated README / GET_STARTED examples so documented runtime versions match `MultiCompress.version(...)`.
- Added third-party license notices for the vendored C libraries.

## [0.3.2]

### Changed
- Micro-optimization

## [0.3.1]

### Fixed
- Data race fix

## [0.3.0]

### Added
- `MultiCompress.configure` with global decompression defaults:
  - `config.max_output_size` for one-shot `MultiCompress.decompress`
  - `config.streaming_max_output_size` for `MultiCompress::Inflater` / `MultiCompress::Reader`
- Per-call `max_output_size:` overrides continue to work and now take precedence over global defaults

### Changed
- One-shot and streaming decompression now use separate defaults out of the box:
  - one-shot `max_output_size`: `512MB`
  - streaming cumulative `max_output_size`: `2GB`
- Size limits are now the primary default UX for decompression while the existing ratio guard behavior remains unchanged.
- Reader/Writer IO parity was tightened for stream wrappers:
  - `Reader#read(n)` now returns `nil` at EOF
  - `Reader#gets` correctly preserves multi-byte separators
  - `Reader#each_chunk` no longer yields an empty trailing chunk at EOF
  - `Writer#puts` now flattens nested arrays like `IO#puts`

## [0.2.4]

### Added
 - Keyword validation

### Fixed
- Fixed gem packaging so vendored builds work correctly after installation.
  Previously, installed gems could incorrectly fall back to system libraries because
  `ext/multi_compress/vendor/.vendored` was not included in the packaged gem.
- Fixed vendored zstd build path in `extconf.rb`.

## [0.2.3]

### Changed
 - Constants

## [0.2.2]

### Added
- New decompression safeguards:
  - `max_output_size:` on `MultiCompress.decompress`, `MultiCompress::Inflater.new`, and `MultiCompress::Reader.open`
  - `max_ratio:` with default `1000` and trusted-input opt-out via `nil`
  - Cumulative streaming output budget enforcement
  - Dictionary file size cap (`32MB`) for `MultiCompress::Dictionary.load`
- New docs/code parity and limits tests
- Local `script/valgrind.sh` helper for developer verification (with Ruby VM suppressions)
- Local `script/sanitize.sh` helper for running ASAN/UBSAN checks on Linux
- Optional `./build.sh --test`, `./build.sh --valgrind`, and `./build.sh --sanitize` modes

### Changed
- Historical note for the 0.2.2 release line: vendored **zstd** was pinned to **1.5.2**.
  - This restored reliable `MultiCompress::Zstd.train_dictionary(...)` behavior on tested platforms at the time, including arm64-darwin.
  - Later releases moved forward after the native-library upgrade path was revalidated.

### Changed
- Documentation now matches current runtime behavior:
  - Ruby requirement is documented as `>= 3.1.0`
  - Supported named levels are `:fastest`, `:default`, and `:best`
  - Zstd `:best` is documented with the current runtime mapping (level 19)
  - LZ4 is documented as using a custom internal format that is not compatible with the standard `lz4` CLI

### Fixed
- Corrected dictionary training docs:
  - `MultiCompress::Zstd.train_dictionary` is documented as supported
  - `MultiCompress::Brotli.train_dictionary` is documented as unsupported in the current implementation

### Notes
- The default `max_ratio: 1000` is a user-visible behavior change. Workloads that legitimately expand beyond `1000:1` must pass `max_ratio: nil`.

## [0.2.1] — 2026-04-15
- Change version zstd "1.5.6" -> "1.5.7".
- Micro optimization.

## [0.2.0] — 2026-04-15

### Added
- **Fiber-friendly execution** 🎉: compression and decompression now cooperate with Ruby's `Fiber::Scheduler`, making MultiCompress safe to use under [async](https://github.com/socketry/async), [falcon](https://github.com/socketry/falcon), and any other scheduler-based runtime.
  - When a scheduler is active, CPU-heavy work is offloaded to a dedicated worker thread via `rb_thread_create`, while the calling fiber is parked with `rb_fiber_scheduler_block`. The scheduler is free to run other fibers (IO, timers, parallel compression) until the worker finishes and calls `rb_fiber_scheduler_unblock`.
  - Covers **all three algorithms** (`zstd`, `lz4`, `brotli`) and **both API shapes**:
    - One-shot `MultiCompress.compress` / `MultiCompress.decompress`
    - Streaming `MultiCompress::Deflater#write` / `MultiCompress::Inflater#write`
  - No API changes — the fiber-friendly path is selected automatically when a scheduler is detected.
  - Chunks smaller than 16 KB (`FIBER_STREAM_THRESHOLD`) stay inline to avoid pthread-create overhead for micro-workloads.
  - Outside of a scheduler, the previous `rb_thread_call_without_gvl` path is used unchanged.
- Generic `run_via_fiber_worker(scheduler, func, arg)` internal helper — encapsulates the pthread-worker + scheduler-block pattern and is reused across every fiber-friendly code path.
- New test suite `test/test_fiber_scheduler.rb` verifying scheduler progress during compress/decompress for every algorithm, in both one-shot and streaming modes.

### Changed
- `fiber_maybe_yield` now actually yields: previously it was a no-op counter; it now calls `Fiber.scheduler.yield` via `rb_funcall` when the byte threshold is crossed. Used for `lz4` streaming paths where pthread-per-block would be overkill.
- Streaming `Deflater#write` for zstd/brotli uses the fiber-worker path for chunks ≥ 16 KB; the old inline path is kept as a fallback for small chunks and when no scheduler is present.
- Streaming `Inflater#write` for zstd/brotli similarly routes chunks through the fiber-worker path when possible.
- LZ4 one-shot decompress loop extracted into `lz4_decompress_all_nogvl` so it can run on the worker thread with the GVL released.

### Performance
- No regressions for the non-fiber case: all existing GVL-unlocking fast paths are preserved untouched.
- Under a fiber scheduler: compression no longer starves concurrent IO fibers. Previously, compressing 50 MB with `zstd` level 3 would block every other fiber in the reactor for the entire duration; now the reactor keeps servicing IO, timers, and other compute fibers throughout.
- Streaming threshold of 16 KB chosen empirically: below that, pthread-create overhead (~20-50μs) eats the gains; at 16 KB+ the fiber-friendly path is a near-free win.

### Upgrading
No code changes required. If you run under `Async`/`Falcon`/`Fiber::Scheduler`, you'll immediately get non-blocking compression. If you don't, behavior is identical to 0.1.2.

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
