# MultiCompress PostgreSQL extension (`MCDB1` reader)

This PostgreSQL extension reads the same frozen `MCDB1` envelopes as the Ruby
API and the MySQL UDF. Rails stores `MultiCompress::Database.compress(text)` in
`bytea`; PostgreSQL exposes decoded UTF-8 through SQL and a view for DBeaver.

It is a separate server-native artifact, not part of `gem install`. The shared
format contract is [`docs/database-envelope-v1.md`](../docs/database-envelope-v1.md).

## SQL API

| Function | Returns | Purpose |
|---|---:|---|
| `multi_compress_db_version()` | `text` | reader build, MCDB1 and zstd version smoke test |
| `multi_compress_db_is_valid(bytea)` | `boolean` | validates an MCDB1 blob without raising |
| `multi_compress_db_decompress(bytea)` | `text` | returns UTF-8 text or raises on corruption |

`multi_compress_db_decompress` requires a UTF-8 PostgreSQL database. MCDB1 does
not permit NUL bytes, so decoded values are valid PostgreSQL `text` values.

## Production deployment: generated DBA bundle

Do **not** ask a DBA to clone this repository, find a release tag, manually copy
`multi_compress_pg.so`, or guess PostgreSQL install paths. The application
developer generates a source bundle from the exact installed gem version:

```bash
bundle exec multi_compress db package postgres --output tmp/multi-compress-postgres.tar.gz
```

The DBA receives that one archive and runs this on the PostgreSQL host:

```bash
tar -xzf multi-compress-postgres.tar.gz
cd multi_compress-postgres-0.5.0
make verify
make doctor
sudo make install
sudo -u postgres make enable DB=app_production \
  MIGRATION_ROLE=app_migrations READ_ROLE=dbeaver_readonly
```

`install` compiles the extension against the selected host `pg_config` and puts
its library/control/SQL files in the directories reported by that exact server.
Install the matching `postgresql-server-dev-<major>` package and a C toolchain
beforehand; `make doctor` verifies both.
For a non-default PostgreSQL install use:

```bash
sudo make install PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

`enable` rejects non-UTF8 databases and an extension already installed in a
different schema. It runs `CREATE EXTENSION` once per application database,
revokes public access, grants the migration role `USAGE` on the extension schema,
and grants both named roles `EXECUTE` on the decoder functions. The application
migration must grant the read role `SELECT` on each generated view. Repeat the
native install on every reporting, failover and restore target before enabling
or querying MCDB1 there.

## DBeaver: generated readable view

Generate the view in the application repository and put the output in a Rails
migration or versioned SQL. It is application schema, not a hand-typed DBA task:

```bash
bundle exec multi_compress db view postgres \
  --table app.events \
  --column payload_compressed \
  --view admin.events_readable \
  --columns id,created_at,status \
  --as payload \
  --output db/views/events_readable.sql
```

DBeaver users only query `admin.events_readable`. Their role needs `USAGE` on
`admin`, `SELECT` on this view, and `EXECUTE` on the decoder functions granted by
`make enable`; it does not need `USAGE` on `multi_compress`. If `make enable`
used a different extension schema, pass it to the generator with
`--extension-schema that_schema`:

```sql
SELECT id, created_at, status, payload
FROM admin.events_readable
WHERE id = 123;
```

The view decompresses selected rows. Filter with indexed ordinary columns before
reading it; do not scan decoded payloads with an unbounded `LIKE '%text%'`.

## Migration and constraints

Do not reinterpret an existing plaintext column as MCDB1. Add a new nullable
`bytea` column, dual-write it from the application, backfill in batches, verify
`multi_compress.multi_compress_db_is_valid(blob)`, switch reads, then keep the
old column for a rollback window. MCDB1 v1 is zstd-only, accepts valid UTF-8
text without NUL bytes, and has a 16 MiB decompressed limit. The target database
must use UTF-8 encoding for the text-returning function.

## Development source build

The source target remains useful for contributors and CI:

```bash
cd postgres_extension
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
make test PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
make e2e
```

`test/run_e2e.sh` builds against a pinned PostgreSQL Docker target and is the
server-side acceptance gate. It is not part of the end-user installation flow.

## MCDB2 dictionary-backed columns

MCDB2 is an opt-in companion for one homogeneous column containing many similar
small JSON/text values. It does not replace MCDB1. First install the 0.6 reader
on every host, then run `make enable` once again to execute `ALTER EXTENSION
multi_compress UPDATE` and refresh function grants.

The dictionary is application data, not an extension file. Create the append-only
registry under a dedicated NOLOGIN owner and retain every version referenced by a
payload:

```bash
bundle exec multi_compress db registry postgres \
  --schema app \
  --owner mcdb_dictionary_owner \
  --migration-role app_migrations \
  --output db/mcdb_dictionary_registry.sql
```

For a new MCDB2 column, add a `payload_dictionary_id bigint NOT NULL` FK to
`app.mcdb_dictionary_versions`, register one strict
`MultiCompress::Database::Dictionary`, then generate the readable view:

```bash
bundle exec multi_compress db view postgres \
  --table app.events \
  --column payload_compressed \
  --dictionary-table app.mcdb_dictionary_versions \
  --dictionary-id-column payload_dictionary_id \
  --view admin.events_readable \
  --columns id,created_at,status \
  --as payload \
  --output db/views/events_readable.sql
```

The generated view uses an `INNER JOIN` and calls the four-argument native
function with payload, registry id, dictionary SHA-256 and bytes. It keeps raw
payloads/dictionary bytes out of the DBeaver role. The view owner needs source
and registry access; DBeaver needs `SELECT` on the view and the decoder
`EXECUTE` grant made by `make enable`.

Check production query shape with `EXPLAIN (ANALYZE, BUFFERS)` on an indexed
filter plus `LIMIT`. Do not search/order/group by decoded payload text. See
[`docs/database-envelope-v2.md`](../docs/database-envelope-v2.md) for the full
format and rollback contract.

For MCDB2 registry DDL, pass `--payload-table`, `--payload-column`, and `--payload-dictionary-id-column` to `multi_compress db registry`; this creates the payload FK and enforces header dictionary-reference consistency.
