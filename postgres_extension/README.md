# MultiCompress PostgreSQL extension (`MCDB1` reader)

This PostgreSQL extension reads the same frozen `MCDB1` envelopes as the Ruby
API and the MySQL UDF. Rails stores `MultiCompress::Database.compress(text)` in
`bytea`; PostgreSQL exposes decoded UTF-8 through SQL and a view for DBeaver.

It is a separate server-native artifact, not part of `gem install`. The shared
format contract is [`docs/database-envelope-v1.md`](../docs/database-envelope-v1.md).

## SQL API

| Function | Returns | Purpose |
|---|---:|---|
| `multi_compress_db_version()` | `text` | smoke test and zstd version |
| `multi_compress_db_is_valid(bytea)` | `boolean` | validates an MCDB1 blob without raising |
| `multi_compress_db_decompress(bytea)` | `text` | returns UTF-8 text or raises on corruption |

`multi_compress_db_decompress` requires a UTF-8 PostgreSQL database. MCDB1 does
not permit NUL bytes, so decoded values are valid PostgreSQL `text` values.

## Build

Build against the headers for the PostgreSQL **major version** that will load
the extension. `pg_config` chooses that server installation.

```bash
cd postgres_extension
make PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
make test PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

The extension statically links the vendored zstd decoder. `make parity` runs the
shared Ruby/C golden fixtures; `make test` builds the PGXS module and then runs
that parity check. The real server gate is `test/run_e2e.sh`.

## Install

On the PostgreSQL host, install the module, control file and extension SQL into
the directories reported by the target `pg_config`:

```bash
cd postgres_extension
sudo make install PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config
```

Then, once per application database:

```sql
CREATE SCHEMA IF NOT EXISTS multi_compress;
CREATE EXTENSION multi_compress WITH SCHEMA multi_compress;
SELECT multi_compress.multi_compress_db_version();
```

`CREATE EXTENSION` normally requires a superuser or a role granted the required
privileges by the DBA. Rebuild/reinstall the `.so` when upgrading to another
PostgreSQL major version. `DROP EXTENSION multi_compress` removes the SQL
functions; it intentionally refuses while views still depend on them.

## DBeaver view

Use a `bytea` column in PostgreSQL. Replace `multi_compress` below if the
extension was installed in another schema:

```sql
CREATE OR REPLACE VIEW events_readable AS
SELECT
  id,
  multi_compress.multi_compress_db_decompress(payload_compressed) AS payload,
  created_at
FROM events;
```

Employees query the view:

```sql
SELECT id, created_at, payload
FROM events_readable
WHERE created_at >= now() - interval '1 day'
ORDER BY id DESC
LIMIT 10;
```

The function decompresses per selected row. Filter by indexed columns before
calling it; do not search the decoded value with `LIKE '%...%'` across a large
table. For content search keep an indexed derived field or use a search system.

## End-to-end acceptance test

`test/run_e2e.sh` requires Docker. It starts the pinned PostgreSQL target,
builds the extension **inside that target container** against its own
`pg_config`, installs the extension files into the server-reported `pkglibdir`
and `sharedir`, executes `CREATE EXTENSION`, validates valid/corrupt MCDB1
blobs, queries a view, and removes the extension. This prevents host libc and
PostgreSQL-header versions from leaking into the artifact.

The default target is the official PostgreSQL 17.9 linux/amd64 manifest.
Override `MCDB_POSTGRES_IMAGE` deliberately to validate your exact PostgreSQL
build. Set `MCDB_PG_SO=/absolute/path/to/multi_compress_pg.so` only to validate
a prebuilt Linux/x86_64 artifact.

## Release artifact

Distribute the Rails gem separately from a PG-major-specific extension artifact:

```text
multi_compress-0.5.0.gem
multi_compress_postgres-0.5.0-linux-x86_64-pg17.tar.gz
SHA256SUMS
```

The PostgreSQL tarball contains `multi_compress_pg.so`, `multi_compress.control`,
`sql/multi_compress--0.5.0.sql`, `sql/views.sql`, `sql/examples.sql`, and this
README. Match it to the PostgreSQL major, CPU architecture and glibc of the
server.
