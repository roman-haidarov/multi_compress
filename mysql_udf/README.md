# MultiCompress MySQL 5.7 UDF (`MCDB1` reader)

Decode-only MySQL loadable functions for the MultiCompress Database envelope v1.
The shared format contract is [`docs/database-envelope-v1.md`](../docs/database-envelope-v1.md).

## SQL API

| Function | Returns | Purpose |
|---|---:|---|
| `multi_compress_db_version()` | STRING | reader build, MCDB1 and zstd version smoke test |
| `multi_compress_db_is_valid(blob)` | INTEGER | `1` for valid MCDB1, `0` for corruption, `NULL` for SQL NULL |
| `multi_compress_db_decompress(blob)` | STRING | decompressed UTF-8 or SQL `NULL` for corruption/SQL NULL |

A MySQL readable view cannot distinguish an original SQL `NULL` from a corrupt
MCDB1 envelope by testing `payload IS NULL`. Diagnose stored values with
`multi_compress_db_is_valid(payload_compressed)`.

## Production deployment: generated DBA bundle

Generate a source bundle from the installed gem:

```bash
bundle exec multi_compress db package mysql --output tmp/multi-compress-mysql.tar.gz
```

On the MySQL 5.7 host, use its local Unix socket:

```bash
tar -xzf multi-compress-mysql.tar.gz
cd multi_compress-mysql-0.5.0
make verify
make doctor MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf MYSQL_SOCKET=/run/mysqld/mysqld.sock
sudo make install MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf MYSQL_SOCKET=/run/mysqld/mysqld.sock
make enable MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf MYSQL_SOCKET=/run/mysqld/mysqld.sock
make status MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf MYSQL_SOCKET=/run/mysqld/mysqld.sock
```

`install` is fresh-install only and refuses to replace a loaded library. A
healthy second `enable` is a no-op. For a library update, use the controlled
maintenance flow:

```bash
sudo make upgrade CONFIRM=UPGRADE_MULTI_COMPRESS \
  MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf MYSQL_SOCKET=/run/mysqld/mysqld.sock
```

`upgrade` captures registrations, drops MultiCompress-owned functions, backs up
the old library, atomically replaces the library, registers functions, and
smoke-checks the reader. On failure it restores the previous library and
registrations. `disable` and `uninstall` are destructive and require:

```bash
make disable CONFIRM=DISABLE_MULTI_COMPRESS \
  MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf MYSQL_SOCKET=/run/mysqld/mysqld.sock
sudo make uninstall CONFIRM=REMOVE_MULTI_COMPRESS \
  MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf MYSQL_SOCKET=/run/mysqld/mysqld.sock
```

The DBA account needs `INSERT` on `mysql` to register functions, `DELETE` to
drop them, and `SELECT` on `mysql.func` for `make status`. The bundle's mysql
client uses `--max_allowed_packet=32M`; mysqld, the Ruby driver, and
DBeaver/JDBC must each support payloads up to the 16 MiB MCDB1 limit.

## DBeaver readable view

The application stores `MultiCompress::Database.compress(text)` in a `LONGBLOB`
column and commits generated view SQL in a migration:

```bash
bundle exec multi_compress db view mysql \
  --table app.events \
  --column payload_compressed \
  --view admin.events_readable \
  --columns id,created_at,status \
  --as payload \
  --output db/views/events_readable.sql
```

MySQL views default to `SQL SECURITY DEFINER`; create the migration with a
stable technical account and do not remove that definer without recreating the
view. Grant the DBeaver role `SELECT` on the resulting view. The generated view
uses `CONVERT(... USING utf8mb4)` so Cyrillic, Kazakh text and emoji display
correctly. Filter by indexed uncompressed columns before selecting through it.

## Multi-host rollout

Build/install the native library on every primary, replica, reporting, failover,
and restore host that will read through the view before registering UDFs or
applying the view migration. A read-only view does not itself replicate the UDF;
replication requires the UDF on a replica only when a replicated statement
invokes it.

`make verify` catches accidental corruption after extraction; it does not
authenticate an archive. Use an out-of-band SHA-256, minisign/GPG signature, or
signed release provenance for a real trust chain.

## MCDB2 dictionary-backed columns

MCDB2 is opt-in for one homogeneous column with many similar small JSON/text
values. Upgrade the UDF library first; the controlled `make upgrade` flow keeps
all MCDB1 and MCDB2 functions registered.

Dictionary bytes are application data. Generate the append-only registry in the
application database, register immutable versions, and retain all referenced
versions in backups and replicas:

```bash
bundle exec multi_compress db registry mysql --database app \
  --output db/mcdb_dictionary_registry.sql
```

For a new MCDB2 column add `payload_dictionary_id BIGINT UNSIGNED NOT NULL` with
a foreign key to `mcdb_dictionary_versions(id)`, then generate the view:

```bash
bundle exec multi_compress db view mysql \
  --table app.events \
  --column payload_compressed \
  --dictionary-table app.mcdb_dictionary_versions \
  --dictionary-id-column payload_dictionary_id \
  --view admin.events_readable \
  --columns id,created_at,status \
  --as payload \
  --output db/views/events_readable.sql
```

The generated MCDB2 view requests `ALGORITHM=MERGE SQL SECURITY DEFINER` and uses
a source-first `STRAIGHT_JOIN` to the registry. That keeps an indexed outer source
predicate from starting at the registry. It passes payload, registry id, SHA-256
and dictionary bytes to the UDF. Keep the definition free of `DISTINCT`, aggregates,
`GROUP BY`, `UNION`, subqueries and inner `LIMIT`; validate real queries with
`EXPLAIN`: source must be a selective `range`/`ref` access and no `<derived>` row
may appear. MySQL 5.7 can still report `Using temporary; Using filesort` for an
outer `ORDER BY` over the joined projection; that is sorting, not view
materialization. A stable definer account must remain part of backup/restore
procedures.

Details are in [`docs/database-envelope-v2.md`](../docs/database-envelope-v2.md).

For MCDB2 registry DDL, pass `--payload-table`, `--payload-column`, and `--payload-dictionary-id-column` to `multi_compress db registry`; this creates the payload FK and enforces header dictionary-reference consistency.
