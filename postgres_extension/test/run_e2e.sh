#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# Platform-specific manifest for postgres:17.9-bookworm on linux/amd64.
DEFAULT_POSTGRES_IMAGE="postgres:17.9-bookworm@sha256:3a69b9de644363f30110fbaa78b9e3298ce71bb1aa9124c0b0ceb0a2602c3283"
IMAGE="${MCDB_POSTGRES_IMAGE:-$DEFAULT_POSTGRES_IMAGE}"
PLATFORM="${MCDB_POSTGRES_PLATFORM:-linux/amd64}"
CONTAINER="${MCDB_POSTGRES_CONTAINER:-mcdb-postgres-e2e}"
WAIT_SECONDS="${MCDB_POSTGRES_WAIT_SECONDS:-90}"
WORK_ROOT="${MCDB_POSTGRES_WORK_ROOT:-$(mktemp -d -t multi-compress-postgres.XXXXXX)}"
REMOVE_WORK_ROOT=0
ARCHIVE="$WORK_ROOT/multi_compress-postgres.tar.gz"
GEM_UNPACK_DIR="$WORK_ROOT/unpacked"
GEM_FILE="$WORK_ROOT/multi_compress.gem"
PACKAGED_GEM_ROOT=""
BUNDLE_PARENT="/opt"

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  [ "$REMOVE_WORK_ROOT" -eq 1 ] && rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

if [ -z "${MCDB_POSTGRES_WORK_ROOT:-}" ]; then
  REMOVE_WORK_ROOT=1
fi

ensure_ruby_extension() {
  if ruby -Ilib -e 'require "multi_compress"; require "multi_compress/database"' >/dev/null 2>&1; then
    return
  fi

  echo "building Ruby extension..."
  if command -v bundle >/dev/null 2>&1; then
    bundle exec rake compile
  else
    rake compile
  fi
  ruby -Ilib -e 'require "multi_compress"; require "multi_compress/database"' >/dev/null
}

require_fixture() {
  local path="$1"
  [ -f "$path" ] || { echo "missing committed fixture: $path" >&2; exit 2; }
}

fixture_hex() {
  ruby -e 'print File.binread(ARGV.fetch(0)).unpack1("H*")' "$1"
}

prepare_packaged_gem() {
  gem build multi_compress.gemspec --output "$GEM_FILE" >/dev/null
  mkdir -p "$GEM_UNPACK_DIR"
  gem unpack "$GEM_FILE" --target "$GEM_UNPACK_DIR" >/dev/null
  shopt -s nullglob
  roots=("$GEM_UNPACK_DIR"/*)
  shopt -u nullglob
  [ "${#roots[@]}" -eq 1 ] && [ -d "${roots[0]}" ] || { echo "could not unpack exactly one multi_compress gem root" >&2; exit 2; }
  PACKAGED_GEM_ROOT="${roots[0]}"
  [ -f "$PACKAGED_GEM_ROOT/multi_compress.gemspec" ] || { echo "packaged gem lacks gemspec" >&2; exit 2; }
  [ -d "$PACKAGED_GEM_ROOT/lib" ] || { echo "packaged gem lacks lib" >&2; exit 2; }
  [ -d "$PACKAGED_GEM_ROOT/exe" ] || { echo "packaged gem lacks exe" >&2; exit 2; }
  [ -f "$PACKAGED_GEM_ROOT/lib/multi_compress/db_deployment.rb" ] || { echo "packaged gem lacks db deployment CLI" >&2; exit 2; }
}

db_cli() {
  ruby -I "$PACKAGED_GEM_ROOT/lib" "$PACKAGED_GEM_ROOT/exe/multi_compress" db "$@"
}

compress_hex() {
  MCDB_TEXT="$1" ruby -Ilib -r multi_compress -r multi_compress/database \
    -e 'print MultiCompress::Database.compress(ENV.fetch("MCDB_TEXT")).unpack1("H*")'
}

mcdb2_fixture() {
  MCDB_TEXT="$1" ruby -Ilib -r multi_compress -r multi_compress/database <<'RUBY'
    samples = 256.times.map do |i|
      %({"kind":"event","tenant":#{i % 8},"metadata":{"source":"worker","version":1,"name":"same-shape-#{i % 16}"},"payload":"#{"x" * (48 + i % 64)}"})
    end

    dictionary = MultiCompress::Database::Dictionary.train(samples, id: 42, size: 4096)
    blob = MultiCompress::Database.compress(ENV.fetch("MCDB_TEXT"), dictionary: dictionary)

    puts dictionary.id
    puts dictionary.zstd_id
    puts dictionary.sha256.unpack1("H*")
    puts dictionary.bytes.unpack1("H*")
    puts blob.unpack1("H*")
RUBY
}

bundle_name() {
  ruby -I "$PACKAGED_GEM_ROOT/lib" -r multi_compress/version \
    -e 'print "multi_compress-postgres-#{MultiCompress::VERSION}"'
}

build_deployment_bundle() {
  db_cli package postgres --output "$ARCHIVE" --force
  test -s "$ARCHIVE"
}

install_postgres_build_tools() {
  local runtime_pg_config="$1"

  docker exec -u 0 \
    -e "MCDB_RUNTIME_PG_CONFIG=$runtime_pg_config" \
    "$CONTAINER" sh -ceu '
      runtime_pg_config="${MCDB_RUNTIME_PG_CONFIG:?missing runtime pg_config}"
      pg_major="$("$runtime_pg_config" --version | awk '\''{print $2}'\'' | cut -d. -f1)"
      case "$pg_major" in
        ""|*[!0-9]*)
          echo "could not determine PostgreSQL major version" >&2
          exit 2
          ;;
      esac

      if ! command -v make >/dev/null 2>&1 || ! command -v cc >/dev/null 2>&1; then
        if ! command -v apt-get >/dev/null 2>&1; then
          echo "PostgreSQL container has no supported package manager" >&2
          exit 2
        fi
        apt-get update >&2
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
          build-essential ca-certificates curl gnupg tar gzip >&2
      fi

      runtime_pgxs="$("$runtime_pg_config" --pgxs 2>/dev/null || true)"
      runtime_headers="$("$runtime_pg_config" --includedir-server 2>/dev/null || true)"
      if [ ! -f "$runtime_pgxs" ] || [ ! -f "$runtime_headers/postgres.h" ]; then
        if ! command -v apt-get >/dev/null 2>&1; then
          echo "PostgreSQL development headers are unavailable" >&2
          exit 2
        fi

        install -d -m 0755 /etc/apt/keyrings
        curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | \
          gpg --dearmor --yes -o /etc/apt/keyrings/postgresql.gpg
        . /etc/os-release
        echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
          >/etc/apt/sources.list.d/pgdg.list
        apt-get update >&2
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
          "postgresql-server-dev-${pg_major}" >&2
      fi

      build_pg_config=""
      for candidate in "/usr/lib/postgresql/${pg_major}/bin/pg_config" "$(command -v pg_config || true)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        pgxs="$("$candidate" --pgxs 2>/dev/null || true)"
        headers="$("$candidate" --includedir-server 2>/dev/null || true)"
        if [ -f "$pgxs" ] && [ -f "$headers/postgres.h" ]; then
          build_pg_config="$candidate"
          break
        fi
      done

      [ -n "$build_pg_config" ] || {
        echo "PostgreSQL PGXS/server headers are unavailable" >&2
        exit 2
      }
      printf "%s\n" "$build_pg_config"
    '
}

install_bundle_on_db_host() {
  local bundle_name="$1"
  local build_pg_config="$2"
  local runtime_pg_config="$3"
  local bundle_root="${BUNDLE_PARENT}/${bundle_name}"

  tar -tzf "$ARCHIVE" | grep -Fx "${bundle_name}/THIRD_PARTY_NOTICES.md" >/dev/null
  if tar -tzf "$ARCHIVE" | grep -E '/\.DS_Store$' >/dev/null; then
    echo 'deployment bundle must not contain .DS_Store' >&2
    exit 2
  fi
  docker cp "$ARCHIVE" "$CONTAINER:/tmp/${bundle_name}.tar.gz"
  docker exec -u 0 \
    -e "MCDB_BUNDLE_ROOT=$bundle_root" \
    -e "MCDB_BUILD_PG_CONFIG=$build_pg_config" \
    -e "MCDB_RUNTIME_PG_CONFIG=$runtime_pg_config" \
    "$CONTAINER" sh -ceu '
      rm -rf "$MCDB_BUNDLE_ROOT"
      mkdir -p "$(dirname "$MCDB_BUNDLE_ROOT")"
      tar -xzf "/tmp/$(basename "$MCDB_BUNDLE_ROOT").tar.gz" -C "$(dirname "$MCDB_BUNDLE_ROOT")"
      cd "$MCDB_BUNDLE_ROOT"
      make verify
      make doctor PG_CONFIG="$MCDB_BUILD_PG_CONFIG"
      make install BUILD_PG_CONFIG="$MCDB_BUILD_PG_CONFIG" RUNTIME_PG_CONFIG="$MCDB_RUNTIME_PG_CONFIG"
    '

}

apply_readable_view() {
  local path="$1"
  db_cli view postgres \
    --table app.events \
    --column payload_compressed \
    --view admin.events_readable \
    --columns id \
    --output "$path"
  docker exec -i "$CONTAINER" psql -X -U app_migrations -d postgres -v ON_ERROR_STOP=1 < "$path"
}

apply_dictionary_readable_view() {
  local path="$1"
  db_cli view postgres \
    --table app.dictionary_events \
    --column payload_compressed \
    --dictionary-table app.mcdb_dictionary_versions \
    --dictionary-id-column payload_dictionary_id \
    --view admin.dictionary_events_readable \
    --columns id \
    --output "$path"
  docker exec -i "$CONTAINER" psql -X -U app_migrations -d postgres -v ON_ERROR_STOP=1 < "$path"
}

ensure_ruby_extension
prepare_packaged_gem
build_deployment_bundle

for name in corrupt_magic corrupt_payload corrupt_crc invalid_utf8 nul_text trailing_skippable trailing_frame; do
  require_fixture "test/fixtures/database_v1/${name}.mcdb"
done

TEXT='Привет, DBeaver! Сәлем! 🌍'
BIG=$(ruby -e 'print "a" * 300')
VALID_HEX=$(compress_hex "$TEXT")
BIG_HEX=$(compress_hex "$BIG")
MCDB2_FIXTURE_OUTPUT="$(mcdb2_fixture "$TEXT")"
readarray -t MCDB2_FIXTURE <<< "$MCDB2_FIXTURE_OUTPUT"
if [ "${#MCDB2_FIXTURE[@]}" -ne 5 ] || [ -z "${MCDB2_FIXTURE[0]}" ] || [ -z "${MCDB2_FIXTURE[4]}" ]; then
  echo "MCDB2 fixture generator returned an invalid payload" >&2
  exit 2
fi
DICT_REF="${MCDB2_FIXTURE[0]}"
DICT_ZSTD_ID="${MCDB2_FIXTURE[1]}"
DICT_SHA_HEX="${MCDB2_FIXTURE[2]}"
DICT_HEX="${MCDB2_FIXTURE[3]}"
DICT_BLOB_HEX="${MCDB2_FIXTURE[4]}"
TEXT_BYTES=$(MCDB_TEXT="$TEXT" ruby -e 'print ENV.fetch("MCDB_TEXT").bytesize')
BUNDLE_NAME="$(bundle_name)"
VIEW_SQL="$(mktemp -t multi-compress-postgres-view.XXXXXX.sql)"
DICT_VIEW_SQL="$(mktemp -t multi-compress-postgres-dictionary-view.XXXXXX.sql)"
REGISTRY_SQL="$(mktemp -t multi-compress-postgres-registry.XXXXXX.sql)"
trap 'rm -f "$VIEW_SQL" "$DICT_VIEW_SQL" "$REGISTRY_SQL"; cleanup' EXIT

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run --platform "$PLATFORM" -d --name "$CONTAINER" \
  -e POSTGRES_HOST_AUTH_METHOD=trust "$IMAGE" >/dev/null

echo "waiting for PostgreSQL in $IMAGE..."
deadline=$(( $(date +%s) + WAIT_SECONDS ))
until docker exec "$CONTAINER" pg_isready -U postgres -d postgres >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "PostgreSQL did not become ready within ${WAIT_SECONDS}s" >&2
    docker logs "$CONTAINER" >&2 || true
    exit 1
  fi
  sleep 2
done

q() { docker exec "$CONTAINER" psql -X -U postgres -d postgres -Atq -v ON_ERROR_STOP=1 -c "$1"; }
qfail() {
  if q "$1" >/dev/null 2>&1; then return 1; else return 0; fi
}
q_read() { docker exec "$CONTAINER" psql -X -U dbeaver_readonly -d postgres -Atq -v ON_ERROR_STOP=1 -c "$1"; }
q_read_fail() {
  if q_read "$1" >/dev/null 2>&1; then return 1; else return 0; fi
}

RUNTIME_PG_CONFIG=$(docker exec "$CONTAINER" sh -ceu 'command -v pg_config' | tr -d '\r\n')
[ -n "$RUNTIME_PG_CONFIG" ] || { echo "PostgreSQL runtime does not provide pg_config" >&2; exit 2; }
BUILD_PG_CONFIG=$(install_postgres_build_tools "$RUNTIME_PG_CONFIG")
install_bundle_on_db_host "$BUNDLE_NAME" "$BUILD_PG_CONFIG" "$RUNTIME_PG_CONFIG"

q "CREATE ROLE app_migrations LOGIN;
   CREATE ROLE dbeaver_readonly LOGIN;
   CREATE ROLE mcdb_dictionary_owner NOLOGIN;
   CREATE SCHEMA app;
   CREATE SCHEMA admin;
   CREATE TABLE app.events (id integer PRIMARY KEY, payload_compressed bytea NULL);
   INSERT INTO app.events VALUES
     (1, decode('$VALID_HEX', 'hex')),
     (2, NULL),
     (3, decode('$BIG_HEX', 'hex')),
     (4, decode('$VALID_HEX', 'hex'));
   GRANT USAGE ON SCHEMA app, admin TO app_migrations, dbeaver_readonly;
   GRANT CREATE ON SCHEMA admin TO app_migrations;
   GRANT SELECT ON app.events TO app_migrations;"
docker exec -u postgres -e "MCDB_BUNDLE_ROOT=${BUNDLE_PARENT}/${BUNDLE_NAME}" "$CONTAINER" sh -ceu '
  cd "$MCDB_BUNDLE_ROOT"
  make enable DB=postgres MIGRATION_ROLE=app_migrations READ_ROLE=dbeaver_readonly
'
apply_readable_view "$VIEW_SQL"
q 'GRANT SELECT ON admin.events_readable TO dbeaver_readonly;'

# MCDB2: package-provided registry DDL, immutable dictionary row, generated INNER JOIN view.
q "CREATE TABLE app.dictionary_events (
     id integer PRIMARY KEY,
     payload_compressed bytea NOT NULL,
     payload_dictionary_id bigint NOT NULL
   );
   GRANT SELECT ON app.dictionary_events TO app_migrations;"
db_cli registry postgres \
  --schema app --owner mcdb_dictionary_owner --migration-role app_migrations \
  --payload-table dictionary_events --payload-column payload_compressed \
  --payload-dictionary-id-column payload_dictionary_id \
  --output "$REGISTRY_SQL"
docker exec -i "$CONTAINER" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 < "$REGISTRY_SQL"
q "
   INSERT INTO app.mcdb_dictionary_versions (id, family, zstd_dict_id, sha256, bytes)
   VALUES ($DICT_REF, 'events_payload_v1', $DICT_ZSTD_ID, decode('$DICT_SHA_HEX', 'hex'), decode('$DICT_HEX', 'hex'));
   INSERT INTO app.dictionary_events (id, payload_compressed, payload_dictionary_id)
   SELECT g, decode('$DICT_BLOB_HEX', 'hex'), $DICT_REF FROM generate_series(1, 1000) AS g;
   ANALYZE app.dictionary_events;"
apply_dictionary_readable_view "$DICT_VIEW_SQL"
q 'GRANT SELECT ON admin.dictionary_events_readable TO dbeaver_readonly;'

q "CREATE DATABASE mcdb_latin1 WITH TEMPLATE template0 ENCODING 'LATIN1' LC_COLLATE 'C' LC_CTYPE 'C';"
docker exec -u postgres -e "MCDB_BUNDLE_ROOT=${BUNDLE_PARENT}/${BUNDLE_NAME}" "$CONTAINER" sh -ceu '
  cd "$MCDB_BUNDLE_ROOT"
  if make enable DB=mcdb_latin1 MIGRATION_ROLE=app_migrations READ_ROLE=dbeaver_readonly >/tmp/mcdb-latin1.out 2>&1; then
    echo "LATIN1 enable unexpectedly succeeded" >&2
    exit 1
  fi
  grep -F "requires UTF8" /tmp/mcdb-latin1.out
'
q "CREATE DATABASE mcdb_other_schema WITH TEMPLATE template0 ENCODING 'UTF8';"
docker exec "$CONTAINER" psql -X -U postgres -d mcdb_other_schema -v ON_ERROR_STOP=1 -c 'CREATE SCHEMA wrong_schema; CREATE EXTENSION multi_compress WITH SCHEMA wrong_schema;' >/dev/null
docker exec -u postgres -e "MCDB_BUNDLE_ROOT=${BUNDLE_PARENT}/${BUNDLE_NAME}" "$CONTAINER" sh -ceu '
  cd "$MCDB_BUNDLE_ROOT"
  if make enable DB=mcdb_other_schema SCHEMA=multi_compress MIGRATION_ROLE=app_migrations READ_ROLE=dbeaver_readonly >/tmp/mcdb-schema.out 2>&1; then
    echo "mismatched extension schema unexpectedly succeeded" >&2
    exit 1
  fi
  grep -F "already installed in schema wrong_schema" /tmp/mcdb-schema.out
'

fails=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got [$2] want [$3])"; fails=$((fails + 1)); fi
}
check_err() {
  if qfail "$2"; then echo "  PASS  $1 (rejected)"; else echo "  FAIL  $1 (should have errored)"; fails=$((fails + 1)); fi
}

check "UTF8 database" "$(q 'SHOW server_encoding;' | tr -d '\r\n')" "UTF8"
check "deployment bundle version() smoke" "$(q 'SELECT strpos(multi_compress.multi_compress_db_version(), chr(77) || chr(67) || chr(68) || chr(66) || chr(49)) > 0;' | tr -d '\r\n')" "t"
check "PostgreSQL reader uses vendored zstd" "$(q "SELECT strpos(multi_compress.multi_compress_db_version(), 'zstd 1.5.7') > 0;" | tr -d '\r\n')" "t"
check "decode roundtrip" "$(q 'SELECT multi_compress.multi_compress_db_decompress(payload_compressed) FROM app.events WHERE id=1;' | tr -d '\r')" "$TEXT"
check "NULL -> NULL" "$(q 'SELECT multi_compress.multi_compress_db_decompress(payload_compressed) IS NULL FROM app.events WHERE id=2;' | tr -d '\r\n')" "t"
check "big (>255, >input)" "$(q 'SELECT octet_length(multi_compress.multi_compress_db_decompress(payload_compressed)) FROM app.events WHERE id=3;' | tr -d '\r\n')" "300"
check "generated readable view" "$(q 'SELECT count(*) FROM admin.events_readable WHERE id IN (1, 4);' | tr -d '\r\n')" "2"
check "read role reads generated Unicode view" "$(q_read 'SELECT payload FROM admin.events_readable WHERE id=1;' | tr -d '\r')" "$TEXT"
if q_read_fail 'SELECT payload_compressed FROM app.events WHERE id=1;'; then
  echo "  PASS  read role cannot read source table"
else
  echo "  FAIL  read role unexpectedly read source table"
  fails=$((fails + 1))
fi
RUNTIME_MAJOR="$(docker exec "$CONTAINER" "$RUNTIME_PG_CONFIG" --version | awk '{print $2}' | cut -d. -f1 | tr -d '\r\n')"
SERVER_MAJOR="$(q 'SHOW server_version;' | cut -d. -f1 | tr -d '\r\n')"
check "connected server major matches PG_CONFIG" "$SERVER_MAJOR" "$RUNTIME_MAJOR"
check "is_valid true" "$(q 'SELECT multi_compress.multi_compress_db_is_valid(payload_compressed) FROM app.events WHERE id=1;' | tr -d '\r\n')" "t"
check "is_valid on NULL" "$(q 'SELECT multi_compress.multi_compress_db_is_valid(payload_compressed) IS NULL FROM app.events WHERE id=2;' | tr -d '\r\n')" "t"

for name in corrupt_magic corrupt_payload corrupt_crc invalid_utf8 nul_text trailing_skippable trailing_frame; do
  hex=$(fixture_hex "test/fixtures/database_v1/${name}.mcdb")
  check_err "$name errors" "SELECT multi_compress.multi_compress_db_decompress(decode('$hex', 'hex'));"
done
check "is_valid false (crc)" "$(q "SELECT multi_compress.multi_compress_db_is_valid(decode('$(fixture_hex test/fixtures/database_v1/corrupt_crc.mcdb)', 'hex'));" | tr -d '\r\n')" "f"
check "MCDB2 registry owner has schema usage" "$(q "SELECT has_schema_privilege('mcdb_dictionary_owner', 'app', 'USAGE');" | tr -d '\r\n')" "t"
check "MCDB2 dictionary reference" "$(q 'SELECT multi_compress.multi_compress_db_dictionary_ref(payload_compressed) FROM app.dictionary_events WHERE id=1;' | tr -d '\r\n')" "$DICT_REF"
check "MCDB2 original size" "$(q 'SELECT multi_compress.multi_compress_db_original_size(payload_compressed) FROM app.dictionary_events WHERE id=1;' | tr -d '\r\n')" "$TEXT_BYTES"
check "MCDB2 dictionary view roundtrip" "$(q_read 'SELECT payload FROM admin.dictionary_events_readable WHERE id=1;' | tr -d '\r')" "$TEXT"
check "MCDB2 dictionary is valid" "$(q "SELECT multi_compress.multi_compress_db_is_valid_dict(e.payload_compressed, e.payload_dictionary_id, d.sha256, d.bytes) FROM app.dictionary_events e JOIN app.mcdb_dictionary_versions d ON d.id = e.payload_dictionary_id WHERE e.id=1;" | tr -d '\r\n')" "t"
check_err "MCDB2 payload/FK mismatch rejected" "INSERT INTO app.dictionary_events VALUES (1001, decode('$DICT_BLOB_HEX', 'hex'), $((DICT_REF + 1)));"
check "MCDB2 rejects wrong dictionary digest" "$(q "SELECT multi_compress.multi_compress_db_is_valid_dict(e.payload_compressed, e.payload_dictionary_id, decode(repeat('00', 32), 'hex'), d.bytes) FROM app.dictionary_events e JOIN app.mcdb_dictionary_versions d ON d.id = e.payload_dictionary_id WHERE e.id=1;" | tr -d '\r\n')" "f"
if q_read_fail 'SELECT bytes FROM app.mcdb_dictionary_versions WHERE id=42;'; then
  echo "  PASS  read role cannot read dictionary registry"
else
  echo "  FAIL  read role unexpectedly read dictionary registry"
  fails=$((fails + 1))
fi
PG_DICT_PLAN="$(q 'SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id, payload FROM admin.dictionary_events_readable WHERE id >= 3 ORDER BY id LIMIT 100;')"
if printf '%s\n' "$PG_DICT_PLAN" | grep -Eq 'Index Scan|Index Only Scan'; then
  echo "  PASS  MCDB2 view preserves indexed LIMIT plan"
else
  echo "  FAIL  MCDB2 view did not expose an indexed LIMIT plan"
  printf '%s\n' "$PG_DICT_PLAN" >&2
  fails=$((fails + 1))
fi

q 'DROP VIEW admin.events_readable; DROP VIEW admin.dictionary_events_readable; DROP EXTENSION multi_compress;'
docker exec "$CONTAINER" psql -X -U postgres -d mcdb_other_schema -v ON_ERROR_STOP=1 -c 'DROP EXTENSION multi_compress;' >/dev/null
docker exec -u 0 -e "MCDB_BUNDLE_ROOT=${BUNDLE_PARENT}/${BUNDLE_NAME}" -e "MCDB_RUNTIME_PG_CONFIG=$RUNTIME_PG_CONFIG" "$CONTAINER" sh -ceu '
  cd "$MCDB_BUNDLE_ROOT"
  if make uninstall RUNTIME_PG_CONFIG="$MCDB_RUNTIME_PG_CONFIG" >/dev/null 2>&1; then
    echo "uninstall succeeded without CONFIRM" >&2
    exit 1
  fi
  make uninstall CONFIRM=REMOVE_MULTI_COMPRESS RUNTIME_PG_CONFIG="$MCDB_RUNTIME_PG_CONFIG"
'
check_err "uninstall removes functions" "SELECT multi_compress.multi_compress_db_version();"
check_err "uninstall removes extension files" "CREATE EXTENSION multi_compress;"

if [ "$fails" -ne 0 ]; then echo "E2E FAILED ($fails)"; exit 1; fi
echo "E2E OK"
