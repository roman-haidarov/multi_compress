# RFC 0002: MCDB2 dictionary-backed SQL-readable database envelopes

**Status:** accepted for MultiCompress 0.6.0

## Decision

Introduce MCDB2 as an opt-in storage format for columns containing many small,
homogeneous UTF-8 documents. MCDB2 uses a zstd dictionary and remains readable from
Ruby, PostgreSQL and MySQL 5.7. MCDB1 is unchanged and remains dictionary-free.

## Non-goals

- No adaptive mixing of MCDB1 and MCDB2 inside one newly designed column.
- No dictionary files in `db package` archives.
- No session registration, global process registry, filesystem lookup, SPI lookup,
  or implicit dictionary lookup inside the native reader.
- No content search on decoded payloads.

## Design

MCDB2 uses the 27-byte format specified in `database-envelope-v2.md`. Its registry
is application-owned, append-only data. Payload rows hold a NOT NULL FK to one
registry version, and a generated trigger rejects a row unless its MCDB2 header
`dictionary_ref` equals that FK. Generated views JOIN that version and pass all four
dictionary arguments to a pure native decoder.

```sql
SELECT e.id,
       multi_compress_db_decompress_dict(
         e.payload_compressed, e.payload_dictionary_id, d.sha256, d.bytes
       ) AS payload
FROM app.events e
JOIN app.mcdb_dictionary_versions d ON d.id = e.payload_dictionary_id;
```

The function cache is a bounded LRU implementation detail, not a source of data.
Its key is `dictionary_id + dictionary_sha256`; cache hits also compare canonical
stored bytes before reuse. This preserves result correctness for direct calls with
arbitrary SQL arguments.

## Access model

The view owner has access to the source table and dictionary registry. DBeaver users
receive only `SELECT` on the view, never source-table or registry-table access.

PostgreSQL needs `EXECUTE` on decoder functions for a role selecting the view; grant
that deliberately to the read role, revoke from PUBLIC, and do not treat the SQL ABI
as a public arbitrary-dictionary API. MySQL views use a stable `SQL SECURITY DEFINER`
account; include that account in backup/restore checks.

## Registry invariants

- version rows are INSERT-only under a dedicated NOLOGIN owner in PostgreSQL;
- `id > 0`, `id <= INT64_MAX` for cross-DB compatibility;
- SHA-256 matches bytes on INSERT;
- zstd DictID is non-zero and matches bytes on INSERT;
- dictionary bytes are at most 256 KiB;
- payload FK deletion is restricted; dictionary bytes are never updated in place.

## Performance contract

The decoder is intentionally in the projection, after a selective indexed predicate.
CI validates PostgreSQL and MySQL query plans for `WHERE id >= ... ORDER BY id LIMIT
10/100/500`. MySQL's generated MCDB2 view uses a source-first `STRAIGHT_JOIN`; the
plan must remain MERGE-able and read the source through a selective range/ref access
before dictionary lookup, with no warning or `<derived>` row. MySQL 5.7 may use a
temporary/filesort implementation for the outer `ORDER BY` over a joined projection;
that does not mean the view itself was materialized. Benchmark acceptance is separate
from timing-sensitive CI: it uses a time-split corpus, warm/cold runs, and concurrent
sessions.

An optional `multi_compress_db_original_size(blob)` helper can support size-aware
administrative queries. PostgreSQL may use it in a stored generated column; MySQL
5.7 must use an ordinary maintained column because loadable UDFs are not supported
in generated columns.
