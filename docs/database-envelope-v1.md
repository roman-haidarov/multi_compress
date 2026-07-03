# MultiCompress Database Envelope — Format v1 (`MCDB1`)

Status: **frozen**. This is a long-term storage contract. Once data is written
to a database column, these bytes must remain readable forever, so v1 will not
change. New capabilities go into a future `v2` with a new version byte.

Two independent implementations MUST agree on this document byte-for-byte:

* the Ruby writer/reader — `MultiCompress::Database` (`lib/multi_compress/database.rb`)
* the MySQL 5.7 reader — `multi_compress_db_decompress()` UDF (`mysql_udf/`)
* the PostgreSQL reader — `multi_compress_db_decompress(bytea)` extension function
  (`postgres_extension/`)

## Scope of v1 (deliberately narrow)

| Aspect              | v1 rule                                              |
|---------------------|------------------------------------------------------|
| Algorithm           | **zstd only** (no lz4, brotli)                       |
| Dictionaries        | **not allowed**                                      |
| Transport encoding  | **raw bytes** (no base64)                            |
| Payload text        | **UTF-8 without U+0000/NUL** (validated on write)    |
| Column type (MySQL) | **`LONGBLOB`** recommended; `MEDIUMBLOB` only if the stored envelope stays < 16 MiB (see note) |
| Column type (PostgreSQL) | **`bytea`**                                      |
| Max decompressed    | **16 MiB** (16777216 bytes), enforced on read AND write |

Anything outside this table is a v2 concern and is out of scope for v1.

**Column sizing.** The 16 MiB cap is on the *decompressed* text. What the column
must hold is the *stored envelope* (`19 bytes + zstd frame`), which is normally
far smaller than the text. But `MEDIUMBLOB` tops out at `2^24 - 1 = 16,777,215`
bytes, one byte below the plaintext cap, and incompressible input can make the
envelope exceed the plaintext size. So v1 recommends **`LONGBLOB`**. Use
`MEDIUMBLOB` only if the application also checks the final `blob.bytesize` before
insert.

## Byte layout

All multi-byte integers are **little-endian**. The envelope is a fixed 19-byte
header followed by a standard zstd frame:

```
 offset  size  field           value / meaning
 ------  ----  --------------  -----------------------------------------------
   0      4    magic           ASCII "MCDB" = 0x4D 0x43 0x44 0x42
   4      1    format_version  0x01
   5      1    codec           0x01 = zstd   (only value allowed in v1)
   6      1    flags           0x00          (reserved; MUST be 0 in v1)
   7      8    original_size   uint64 LE: byte length of the original UTF-8 text
  15      4    crc32           uint32 LE: CRC-32 (zlib/IEEE) of the original text
  19      N    zstd_frame      a standard zstd frame produced from the text
```

Total stored size = `19 + N` bytes.

`original_size` is the length of the **decompressed** UTF-8 bytes, stored
explicitly so a reader can pre-allocate exactly. `crc32` is the standard
zlib/IEEE CRC-32 of those same original bytes.

**Why an explicit CRC-32.** A raw zstd frame carries no content checksum by
default, so a single flipped byte in the payload can decode to a value of the
correct length with corrupted contents that zstd cannot detect. v1 therefore
stores a CRC-32 of the plaintext and every reader verifies it after
decompression. This matches Ruby's `MultiCompress.crc32`.

CRC-32 detects accidental corruption (bit flips, truncation, wrong bytes) with a
small residual collision probability; it is **not** a cryptographic integrity or
authenticity mechanism. For trusted database storage that is the intended use.
If envelopes could be altered by an untrusted party, a keyed cryptographic
digest would be required — that is a different, future format, not v1.

### Empty text

An empty string is valid: `original_size = 0`, and `zstd_frame` is the zstd
frame of a zero-length input. The reader returns an empty string.

## Writer algorithm (compress)

1. Require input is a `String` whose bytes are valid UTF-8 and contain no NUL byte; else error.
2. Let `n = bytesize`. If `n > 16777216`, error (too large for v1).
3. `crc = crc32(bytes)` (zlib/IEEE).
4. `frame = zstd_compress(bytes)`.
5. Emit `"MCDB" + 0x01 + 0x01 + 0x00 + le_uint64(n) + le_uint32(crc) + frame`.

## Reader algorithm (decompress / validate)

A reader MUST reject, with an error (never a silent fallback), any input that
fails any check below:

1. `19 <= length <= 16842771` (a complete, bounded envelope).
2. `magic == "MCDB"`.
3. `format_version == 0x01`.
4. `codec == 0x01`.
5. `flags == 0x00`.
6. `original_size <= 16777216`.
7. The payload is **exactly one** standard zstd frame: no skippable frame,
   concatenated frame, or trailing byte is allowed.
8. The zstd frame declares a content size and that size equals `original_size`.
9. `zstd_decompress(frame)` succeeds with a bounded output of at most
   `original_size` bytes.
10. The produced byte length equals `original_size` exactly.
11. `crc32(produced) == crc32` from the header.
12. The produced bytes are valid UTF-8 and contain no NUL byte.

On success the reader returns a UTF-8 string. MySQL callers can expose it with
`CONVERT(... USING utf8mb4)`. PostgreSQL callers use the `text`-returning
extension function and therefore require a UTF-8 database encoding.

`multi_compress_db_is_valid(blob)` performs checks 1–12 and returns 1/0 without
raising, so it can be used in `WHERE`/`CASE`.

## Error taxonomy

| Condition | Ruby | MySQL UDF / PostgreSQL extension |
|-----------|------|----------------------------------|
| truncated / oversized envelope / bad magic / version | `MultiCompress::DataError` | SQL error |
| codec/flags not v1 | `MultiCompress::DataError` | SQL error |
| `original_size` over the cap | `MultiCompress::DataError` | SQL error |
| invalid, trailing, or concatenated zstd frame / size mismatch | `MultiCompress::DataError` | SQL error |
| crc32 mismatch (payload corruption) | `MultiCompress::DataError` | SQL error |
| non-UTF-8 or NUL text on write or read | `ArgumentError` / `MultiCompress::DataError` | SQL error |

## Versioning policy

* The 4-byte magic `MCDB` is a reserved namespace.
* `format_version` gates the whole layout. A reader that does not recognise the
  version MUST error, not guess.
* v1 is immutable. Format changes ship as v2 (`format_version = 0x02`) with its
  own spec document; readers dispatch on the version byte.

## Migration note

v1 has **no legacy/plaintext auto-detection**. To migrate an existing text
column, add a new `LONGBLOB` column and write the envelope there; never
reinterpret old plaintext bytes as an envelope. See the rollout steps in
`mysql_udf/README.md` or `postgres_extension/README.md`.
