# MCDB2 database envelope (dictionary-backed, version 2)

MCDB2 is an opt-in, dictionary-backed companion to [MCDB1](database-envelope-v1.md).
It exists for a **single homogeneous database column** whose values share a stable
text/JSON shape. Every MCDB2 value requires the exact immutable dictionary version
recorded with it. MCDB1 remains the default for dictionary-free, heterogeneous, or
large values.

MCDB2 is compression, not encryption. Its CRC-32 detects accidental corruption; it
does not authenticate data.

## Wire format

All integer fields are little-endian.

| Offset | Size | Field | Required value |
|---:|---:|---|---|
| 0 | 4 | magic | ASCII `MCDB` |
| 4 | 1 | format version | `0x02` |
| 5 | 1 | codec | `0x01` (zstd) |
| 6 | 1 | reserved flags | `0x00` |
| 7 | 8 | original UTF-8 byte size | `0..16 MiB` |
| 15 | 4 | CRC-32 | IEEE/zlib CRC of plaintext |
| 19 | 8 | `dictionary_ref` | application registry id, `1..INT64_MAX` |
| 27 | ... | zstd frame | exactly one frame with a non-zero zstd DictID |

The maximum stored envelope is 16,842,779 bytes (`27 + ZSTD_compressBound(16 MiB)`).

`dictionary_ref` is **not** the zstd DictID. It is a signed-bigint-compatible,
application-level immutable primary key. The zstd frame contains the zstd DictID;
readers require that it equals `ZSTD_getDictID_fromDict(dictionary_bytes)`.

## Writer requirements

A writer MUST:

1. accept only valid UTF-8 text without NUL bytes and at most 16 MiB;
2. use a conformant zstd dictionary no larger than 256 KiB with non-zero DictID;
3. use a positive registry id at most `INT64_MAX`;
4. emit a zstd frame through a prepared CDict so its DictID and content size are set;
5. emit the 27-byte MCDB2 header followed by exactly that frame.

Ruby API:

```ruby
samples = historical_payloads

dictionary = MultiCompress::Database::Dictionary.train(
  samples,
  id: 42,
  size: 32 * 1024
)

blob = MultiCompress::Database.compress(payload_json, dictionary: dictionary)
```

## Reader requirements

The supported SQL ABI has four arguments:

```sql
multi_compress_db_decompress_dict(
  blob,
  dictionary_id,
  dictionary_sha256,
  dictionary_bytes
)
```

The reader rejects any value unless all checks hold:

1. the MCDB2 header is valid and `header.dictionary_ref == dictionary_id`;
2. `dictionary_sha256` is 32 bytes and equals SHA-256 of `dictionary_bytes`;
3. dictionary bytes are a conformant zstd dictionary with a non-zero DictID;
4. the frame has exactly one zstd frame and its DictID equals the supplied dictionary's zstd DictID;
5. the frame content size equals the header size; decompression, CRC-32 and UTF-8/NUL checks pass.

`multi_compress_db_is_valid_dict(...)` returns false/0 rather than raising for an
invalid non-NULL input. PostgreSQL `decompress_dict` raises a SQL error; MySQL 5.7
returns SQL `NULL`, matching the MCDB1 UDF policy.

## Dictionary registry

Dictionary bytes are **application data**, not part of the DBA reader bundle.
Store them in an append-only registry table in the application database. A rotation
creates a new version row and changes only a movable `dictionary_heads` pointer;
old rows and old payloads continue to reference their original version.

Generate starter DDL:

```bash
multi_compress db registry postgres \
  --schema app --owner mcdb_dictionary_owner \
  --migration-role app_migrations \
  --payload-table events --payload-column payload_compressed \
  --payload-dictionary-id-column payload_dictionary_id \
  > db/mcdb_dictionary_registry.sql

multi_compress db registry mysql --database app \
  --payload-table events --payload-column payload_compressed \
  --payload-dictionary-id-column payload_dictionary_id \
  > db/mcdb_dictionary_registry.sql
```

The registry DDL validates id/hash/zstd-ID/size at insert time and rejects updates
and deletes. When the three `--payload-*` options are supplied, it also creates the
payload FK and a trigger requiring `header.dictionary_ref == payload_dictionary_id`.
For PostgreSQL it grants `USAGE` on the application schema to the dedicated NOLOGIN
registry owner: internal FK checks run with relation-owner privileges and require
that schema privilege. Backups, replication and restores therefore carry dictionaries
with the compressed rows that require them.

## Readable views

Generate an MCDB2 view with an INNER JOIN. MySQL 5.7 output uses a source-first
`STRAIGHT_JOIN` internally so an indexed source predicate does not begin from the
registry. A MySQL 5.7 `EXPLAIN` may still report `Using temporary; Using filesort`
for an outer `ORDER BY` over the joined projection; this is sorting, not view
materialization. The view must expose no raw compressed column or dictionary bytes
to DBeaver users:

```bash
multi_compress db view postgres \
  --table app.events --column payload_compressed \
  --dictionary-table app.mcdb_dictionary_versions \
  --dictionary-id-column payload_dictionary_id \
  --view admin.events_readable --columns id,created_at,status --as payload
```

For MySQL 5.7 the generator emits `ALGORITHM=MERGE SQL SECURITY DEFINER`. Do not
add `DISTINCT`, aggregates, `GROUP BY`, `UNION`, subqueries, or an inner `LIMIT` to
the generated view; they can force materialization and make decoding happen before
an outer filter/limit.

Filter and order only by ordinary indexed columns. Keep decoding in the SELECT list.
Use `EXPLAIN` for production query shapes such as `WHERE id >= ... ORDER BY id LIMIT 100`.

## Rollout and rollback

1. Install 0.6 readers on every DB reader host before writing an MCDB2 row.
2. PostgreSQL: run `ALTER EXTENSION multi_compress UPDATE`; MySQL: use the bundle's
   controlled UDF upgrade flow, which preserves both MCDB1 and MCDB2 functions.
3. Create registry, registry validation/freeze triggers, source FK, and readable view.
4. Train/register a dictionary and enable the MCDB2 writer for its new column.

After the first MCDB2 write, a reader at 0.5.x cannot read that row. Roll back the
application writer first; retain 0.6 readers until all MCDB2 values are retired.
