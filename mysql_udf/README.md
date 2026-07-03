# MultiCompress MySQL 5.7 UDF (`MCDB1` reader)

Decode-only MySQL loadable functions for the MultiCompress Database envelope v1.
The application (Rails/Ruby) writes compressed text into a `LONGBLOB`; these
functions let employees read the text back through plain SQL / a view in DBeaver.

This is a **separate native target** from the Ruby gem — different ABI, build,
and deployment. It shares only the frozen byte format
([`docs/database-envelope-v1.md`](../docs/database-envelope-v1.md)) and the
vendored zstd sources.

## SQL functions

| Function | Returns | Purpose |
|----------|---------|---------|
| `multi_compress_db_version()` | STRING | `MCDB1 (zstd 1.5.7)` — smoke test |
| `multi_compress_db_is_valid(blob)` | INTEGER | `1`/`0`, safe in `WHERE`/`CASE` |
| `multi_compress_db_decompress(blob)` | STRING | decompressed UTF-8, or SQL error on corruption |

Compression is **not** exposed to SQL: envelopes are produced by the app.

## Build

The default target uses the bundled MySQL 5.7 UDF ABI declaration, so it does
not depend on whichever client headers happen to be installed on the build host.

```bash
cd mysql_udf
make udf                              # -> build/multi_compress_mysql.so
make udf MYSQL_UDF_ABI=system MYSQL_INCLUDE=/path/to/mysql/include
```

`MYSQL_UDF_ABI=system` is only for deliberately building against a compatible
server-family header set.

`make test` builds a standalone harness (no MySQL needed) that decodes the Ruby
golden fixtures in `../test/fixtures/database_v1/` and verifies byte-for-byte
parity plus rejection of the corrupt fixtures.

## Install

```sql
SHOW VARIABLES LIKE 'plugin_dir';           -- e.g. /usr/lib/mysql/plugin
-- copy build/multi_compress_mysql.so into plugin_dir, then:
SOURCE sql/install.sql;                      -- registers the 3 functions
SELECT multi_compress_db_version();          -- verify
```

Uninstall with `sql/uninstall.sql`. Requires admin rights on the MySQL server
(ability to place a `.so` in `plugin_dir` and run `CREATE FUNCTION ... SONAME`).
A MySQL upgrade can require rebuilding/reinstalling the `.so`.

## Use from DBeaver

Create a per-table view (`sql/views.sql`) and read that:

```sql
CREATE OR REPLACE VIEW events_readable AS
SELECT id,
       CONVERT(multi_compress_db_decompress(payload_compressed) USING utf8mb4) AS payload,
       created_at
FROM events;

SELECT * FROM events_readable WHERE id = 123;
```

The view decompresses **per row**. It is for diagnostics and narrow, indexed
lookups (id / date / status + `LIMIT`). Do not build heavy analytics on it and
never filter with `WHERE multi_compress_db_decompress(...) LIKE '%...%'`.

## End-to-end acceptance test

`test/run_e2e.sh` (needs Docker) is the real gate: Ruby writes a blob → MySQL
5.7 reports its actual `plugin_dir` → the script installs the UDF there → SQL
reads it back and exercises the shipped install/uninstall scripts.

The script defaults to the immutable official `mysql:5.7.44` linux/amd64
manifest digest, rather than a floating tag. By default it builds the UDF
**inside that target container** using the bundled MySQL 5.7 ABI declaration.
This prevents the host libc and client-header version from leaking into the
server artifact.

Set `MCDB_UDF_SO=/absolute/path/to/multi_compress_mysql.so` only when you
intentionally want to validate a prebuilt Linux/x86_64 artifact.

Override `MCDB_MYSQL_IMAGE` only deliberately, for example to test the exact
Percona or MySQL 8.0 build you operate. Run the gate against every MySQL
family/version you deploy.

## Migration (no ambiguous legacy format)

Do not reinterpret existing plaintext as an envelope. Roll out with a new column:

1. Add `payload_compressed LONGBLOB NULL`.
2. Deploy the app writing both the old text and the new envelope.
3. Backfill old rows in batches; verify counts and `SHA-256(original)` vs
   `SHA-256(decompress(blob))`.
4. Switch app reads to the compressed column.
5. Keep the old column for a rollback window, then drop/archive it.

During migration use the `CASE ... WHEN payload_compressed IS NULL` view variant
in `sql/views.sql`.

## Constraints (v1)

zstd only; UTF-8 text without NUL bytes; `LONGBLOB` (or `MEDIUMBLOB` with an app-side bytesize check); 16 MiB max decompressed; no
dictionaries; no base64. The payload must be exactly one standard zstd frame;
concatenated frames, skippable frames, and trailing bytes are rejected. A detected
format error is a hard SQL error, never a silent fallback. CRC-32 is for accidental
corruption detection, not cryptographic authenticity.

## Release artifacts

The gem does not ship the UDF (it must not compile at `gem install`). Deliver the
MySQL side as a separate artifact per release, e.g. a GitHub release containing:

```
multi_compress-0.5.0.gem
multi_compress_mysql-0.5.0-linux-x86_64-mysql57.tar.gz   # .so + sql/ + README
SHA256SUMS
```

Build the tarball on a host matching the target glibc/MySQL ABI:

```bash
cd mysql_udf
make udf MYSQL_UDF_ABI=mysql57
tar czf multi_compress_mysql-0.5.0-linux-x86_64-mysql57.tar.gz \
    build/multi_compress_mysql.so sql/ README.md
sha256sum multi_compress-0.5.0.gem multi_compress_mysql-*.tar.gz > SHA256SUMS
```

A gem user then gets the Ruby API from RubyGems and the `.so` + SQL from the
release; the two are matched by version and by `docs/database-envelope-v1.md`.

## If you cannot install a UDF

If your MySQL servers don't allow placing a `.so` in `plugin_dir` or running
`CREATE FUNCTION`, transparent in-DBeaver decoding isn't possible. Alternatives:
keep an uncompressed column for human reading, or give staff a small CLI/web
tool that runs `MultiCompress::Database.decompress`.
