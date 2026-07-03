#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

# Platform-specific manifest for postgres:17.9-bookworm on linux/amd64.
DEFAULT_POSTGRES_IMAGE="postgres:17.9-bookworm@sha256:3a69b9de644363f30110fbaa78b9e3298ce71bb1aa9124c0b0ceb0a2602c3283"
IMAGE="${MCDB_POSTGRES_IMAGE:-$DEFAULT_POSTGRES_IMAGE}"
PLATFORM="${MCDB_POSTGRES_PLATFORM:-linux/amd64}"
CONTAINER="${MCDB_POSTGRES_CONTAINER:-mcdb-postgres-e2e}"
WAIT_SECONDS="${MCDB_POSTGRES_WAIT_SECONDS:-90}"
PREBUILT_PG_SO="${MCDB_PG_SO:-}"
BUILD_ROOT="/tmp/mcdb-build"

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

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

compress_hex() {
  MCDB_TEXT="$1" ruby -Ilib -r multi_compress -r multi_compress/database \
    -e 'print MultiCompress::Database.compress(ENV.fetch("MCDB_TEXT")).unpack1("H*")'
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
          echo "PostgreSQL container has no supported package manager; set MCDB_PG_SO" >&2
          exit 2
        fi
        apt-get update >&2
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
          build-essential ca-certificates curl gnupg >&2
      fi

      runtime_pgxs="$("$runtime_pg_config" --pgxs 2>/dev/null || true)"
      runtime_headers="$("$runtime_pg_config" --includedir-server 2>/dev/null || true)"
      if [ ! -f "$runtime_pgxs" ] || [ ! -f "$runtime_headers/postgres.h" ]; then
        if ! command -v apt-get >/dev/null 2>&1; then
          echo "PostgreSQL development headers are unavailable; set MCDB_PG_SO" >&2
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
        echo "PostgreSQL PGXS/server headers are unavailable; set MCDB_PG_SO" >&2
        exit 2
      }
      printf "%s\n" "$build_pg_config"
    '
}

copy_postgres_build_tree() {
  docker exec -u 0 "$CONTAINER" rm -rf "$BUILD_ROOT"
  docker exec -u 0 "$CONTAINER" mkdir -p "$BUILD_ROOT/ext/multi_compress"
  docker cp "$PWD/db_core" "$CONTAINER:${BUILD_ROOT}/"
  docker cp "$PWD/postgres_extension" "$CONTAINER:${BUILD_ROOT}/"
  docker cp "$PWD/ext/multi_compress/vendor" "$CONTAINER:${BUILD_ROOT}/ext/multi_compress/"
}

build_or_copy_extension() {
  if [ -n "$PREBUILT_PG_SO" ]; then
    [ -f "$PREBUILT_PG_SO" ] || { echo "MCDB_PG_SO does not exist: $PREBUILT_PG_SO" >&2; exit 2; }
    SO_IN_CONTAINER="/tmp/multi_compress_pg.so"
    docker cp "$PREBUILT_PG_SO" "$CONTAINER:$SO_IN_CONTAINER"
  else
    BUILD_PG_CONFIG=$(install_postgres_build_tools "$RUNTIME_PG_CONFIG")
    copy_postgres_build_tree
    docker exec -u 0 "$CONTAINER" sh -ceu \
      "make -C '$BUILD_ROOT/postgres_extension' clean all PG_CONFIG='$BUILD_PG_CONFIG'"
    SO_IN_CONTAINER="$BUILD_ROOT/postgres_extension/multi_compress_pg.so"
  fi

  docker exec "$CONTAINER" test -f "$SO_IN_CONTAINER"
}

ensure_ruby_extension

for name in corrupt_magic corrupt_payload corrupt_crc invalid_utf8 nul_text trailing_skippable trailing_frame; do
  require_fixture "test/fixtures/database_v1/${name}.mcdb"
done

TEXT='Привет, DBeaver! Сәлем! 🌍'
BIG=$(ruby -e 'print "a" * 300')
VALID_HEX=$(compress_hex "$TEXT")
BIG_HEX=$(compress_hex "$BIG")

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

RUNTIME_PG_CONFIG=$(docker exec "$CONTAINER" sh -ceu 'command -v pg_config' | tr -d '\r\n')
[ -n "$RUNTIME_PG_CONFIG" ] || { echo "PostgreSQL runtime does not provide pg_config" >&2; exit 2; }

build_or_copy_extension

PKGLIBDIR=$(docker exec "$CONTAINER" "$RUNTIME_PG_CONFIG" --pkglibdir | tr -d '\r\n')
SHAREDIR=$(docker exec "$CONTAINER" "$RUNTIME_PG_CONFIG" --sharedir | tr -d '\r\n')
[ -n "$PKGLIBDIR" ] && [ -n "$SHAREDIR" ] || { echo "PostgreSQL returned empty install paths" >&2; exit 1; }
docker exec "$CONTAINER" test -d "$PKGLIBDIR"
docker exec "$CONTAINER" test -d "$SHAREDIR/extension"

docker exec -u 0 "$CONTAINER" cp "$SO_IN_CONTAINER" "${PKGLIBDIR%/}/multi_compress_pg.so"
docker cp postgres_extension/multi_compress.control "$CONTAINER:${SHAREDIR%/}/extension/multi_compress.control"
docker cp postgres_extension/sql/multi_compress--0.5.0.sql "$CONTAINER:${SHAREDIR%/}/extension/multi_compress--0.5.0.sql"
docker exec -u 0 "$CONTAINER" chmod 755 "${PKGLIBDIR%/}/multi_compress_pg.so"

fails=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got [$2] want [$3])"; fails=$((fails + 1)); fi
}
check_err() {
  if qfail "$2"; then echo "  PASS  $1 (rejected)"; else echo "  FAIL  $1 (should have errored)"; fails=$((fails + 1)); fi
}

q "CREATE SCHEMA multi_compress;
   CREATE EXTENSION multi_compress WITH SCHEMA multi_compress;
   CREATE SCHEMA app;
   CREATE TABLE app.events (id integer PRIMARY KEY, payload_compressed bytea NULL);
   INSERT INTO app.events VALUES
     (1, decode('$VALID_HEX', 'hex')),
     (2, NULL),
     (3, decode('$BIG_HEX', 'hex')),
     (4, decode('$VALID_HEX', 'hex'));
   CREATE VIEW app.events_readable AS
     SELECT id, multi_compress.multi_compress_db_decompress(payload_compressed) AS payload
     FROM app.events;"

check "UTF8 database" "$(q 'SHOW server_encoding;' | tr -d '\r\n')" "UTF8"
check "version() smoke" "$(q 'SELECT left(multi_compress.multi_compress_db_version(), 5);' | tr -d '\r\n')" "MCDB1"
check "decode roundtrip" "$(q 'SELECT multi_compress.multi_compress_db_decompress(payload_compressed) FROM app.events WHERE id=1;' | tr -d '\r')" "$TEXT"
check "NULL -> NULL" "$(q 'SELECT multi_compress.multi_compress_db_decompress(payload_compressed) IS NULL FROM app.events WHERE id=2;' | tr -d '\r\n')" "t"
check "big (>255, >input)" "$(q 'SELECT octet_length(multi_compress.multi_compress_db_decompress(payload_compressed)) FROM app.events WHERE id=3;' | tr -d '\r\n')" "300"
check "multi-row via view" "$(q 'SELECT count(*) FROM app.events_readable WHERE id IN (1, 4);' | tr -d '\r\n')" "2"
check "is_valid true" "$(q 'SELECT multi_compress.multi_compress_db_is_valid(payload_compressed) FROM app.events WHERE id=1;' | tr -d '\r\n')" "t"
check "is_valid on NULL" "$(q 'SELECT multi_compress.multi_compress_db_is_valid(payload_compressed) IS NULL FROM app.events WHERE id=2;' | tr -d '\r\n')" "t"

for name in corrupt_magic corrupt_payload corrupt_crc invalid_utf8 nul_text trailing_skippable trailing_frame; do
  hex=$(fixture_hex "test/fixtures/database_v1/${name}.mcdb")
  check_err "$name errors" "SELECT multi_compress.multi_compress_db_decompress(decode('$hex', 'hex'));"
done
check "is_valid false (crc)" "$(q "SELECT multi_compress.multi_compress_db_is_valid(decode('$(fixture_hex test/fixtures/database_v1/corrupt_crc.mcdb)', 'hex'));" | tr -d '\r\n')" "f"

q 'DROP VIEW app.events_readable; DROP EXTENSION multi_compress;'
check_err "uninstall removes functions" "SELECT multi_compress.multi_compress_db_version();"

if [ "$fails" -ne 0 ]; then echo "E2E FAILED ($fails)"; exit 1; fi
echo "E2E OK"
