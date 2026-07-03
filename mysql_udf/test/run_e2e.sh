#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

DEFAULT_MYSQL_IMAGE="mysql:5.7.44@sha256:dab0a802b44617303694fb17d166501de279c3031ddeb28c56ecf7fcab5ef0da"
IMAGE="${MCDB_MYSQL_IMAGE:-$DEFAULT_MYSQL_IMAGE}"
PLATFORM="${MCDB_MYSQL_PLATFORM:-linux/amd64}"
CONTAINER="${MCDB_MYSQL_CONTAINER:-mcdb-e2e}"
WAIT_SECONDS="${MCDB_MYSQL_WAIT_SECONDS:-90}"
PREBUILT_UDF_SO="${MCDB_UDF_SO:-}"
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

install_mysql_build_tools() {
  docker exec -u 0 "$CONTAINER" sh -ceu '
    if command -v yum >/dev/null 2>&1; then
      yum install -y gcc make binutils
    elif command -v microdnf >/dev/null 2>&1; then
      microdnf install -y gcc make binutils
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential
    else
      echo "no supported package manager in MySQL container" >&2
      exit 2
    fi

    command -v cc
    command -v make
    command -v ar
  '
}

copy_mysql_build_tree() {
  docker exec -u 0 "$CONTAINER" rm -rf "$BUILD_ROOT"
  docker exec -u 0 "$CONTAINER" mkdir -p "$BUILD_ROOT/ext/multi_compress"
  docker cp "$PWD/db_core" "$CONTAINER:${BUILD_ROOT}/"
  docker cp "$PWD/mysql_udf" "$CONTAINER:${BUILD_ROOT}/"
  docker cp "$PWD/ext/multi_compress/vendor" "$CONTAINER:${BUILD_ROOT}/ext/multi_compress/"
}

build_or_copy_udf() {
  if [ -n "$PREBUILT_UDF_SO" ]; then
    [ -f "$PREBUILT_UDF_SO" ] || { echo "MCDB_UDF_SO does not exist: $PREBUILT_UDF_SO" >&2; exit 2; }
    SO_IN_CONTAINER="/tmp/multi_compress_mysql.so"
    docker cp "$PREBUILT_UDF_SO" "$CONTAINER:$SO_IN_CONTAINER"
  else
    install_mysql_build_tools
    copy_mysql_build_tree
    docker exec -u 0 "$CONTAINER" sh -ceu \
      "make -C '$BUILD_ROOT/mysql_udf' clean udf MYSQL_UDF_ABI=mysql57"
    SO_IN_CONTAINER="$BUILD_ROOT/mysql_udf/build/multi_compress_mysql.so"
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
  -e MYSQL_ALLOW_EMPTY_PASSWORD=1 "$IMAGE" \
  --character-set-server=utf8mb4 \
  --collation-server=utf8mb4_unicode_ci >/dev/null

echo "waiting for mysqld in $IMAGE..."
deadline=$(( $(date +%s) + WAIT_SECONDS ))
until docker exec "$CONTAINER" mysqladmin ping --silent 2>/dev/null; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "mysqld did not become ready within ${WAIT_SECONDS}s" >&2
    docker logs "$CONTAINER" >&2 || true
    exit 1
  fi
  sleep 2
done

q() {
  docker exec "$CONTAINER" mysql \
    --default-character-set=utf8mb4 \
    --batch \
    --skip-column-names \
    --raw \
    -e "$1"
}
qfail() {
  if q "$1" >/dev/null 2>&1; then return 1; else return 0; fi
}

build_or_copy_udf

PLUGIN_DIR=$(q 'SELECT @@plugin_dir;' | tr -d '\r\n')
[ -n "$PLUGIN_DIR" ] || { echo "MySQL returned an empty plugin_dir" >&2; exit 1; }
docker exec "$CONTAINER" test -d "$PLUGIN_DIR"
docker exec -u 0 "$CONTAINER" cp "$SO_IN_CONTAINER" "${PLUGIN_DIR%/}/multi_compress_mysql.so"
docker exec -u 0 "$CONTAINER" chmod 755 "${PLUGIN_DIR%/}/multi_compress_mysql.so"
docker exec -i "$CONTAINER" mysql < mysql_udf/sql/install.sql

fails=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got [$2] want [$3])"; fails=$((fails + 1)); fi
}
check_err() {
  if qfail "$2"; then echo "  PASS  $1 (rejected)"; else echo "  FAIL  $1 (should have errored)"; fails=$((fails + 1)); fi
}

q "DROP DATABASE IF EXISTS app;
   CREATE DATABASE app CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   USE app;
   CREATE TABLE events (id INT PRIMARY KEY, payload_compressed LONGBLOB NULL);
   INSERT INTO events VALUES
     (1, UNHEX('$VALID_HEX')),
     (2, NULL),
     (3, UNHEX('$BIG_HEX')),
     (4, UNHEX('$VALID_HEX'));
   CREATE OR REPLACE VIEW events_readable AS
     SELECT id, CONVERT(multi_compress_db_decompress(payload_compressed) USING utf8mb4) AS payload
     FROM events;"

check "version() smoke" "$(q 'SELECT LEFT(multi_compress_db_version(), 5);')" "MCDB1"
check "MySQL connection uses utf8mb4" \
  "$(q "SELECT CONCAT(@@character_set_client, '/', @@character_set_connection, '/', @@character_set_results);")" \
  "utf8mb4/utf8mb4/utf8mb4"
check "decode roundtrip" \
  "$(q 'USE app; SELECT CONVERT(multi_compress_db_decompress(payload_compressed) USING utf8mb4) FROM events WHERE id=1;')" \
  "$TEXT"
check "NULL -> NULL" "$(q 'USE app; SELECT multi_compress_db_decompress(payload_compressed) IS NULL FROM events WHERE id=2;')" "1"
check "big (>255, >input)" "$(q 'USE app; SELECT OCTET_LENGTH(multi_compress_db_decompress(payload_compressed)) FROM events WHERE id=3;')" "300"
check "multi-row via view" "$(q 'USE app; SELECT COUNT(*) FROM events_readable WHERE id IN (1, 4);')" "2"
check "is_valid true" "$(q 'USE app; SELECT multi_compress_db_is_valid(payload_compressed) FROM events WHERE id=1;')" "1"
check "is_valid on NULL" "$(q 'USE app; SELECT multi_compress_db_is_valid(payload_compressed) IS NULL FROM events WHERE id=2;')" "1"

for name in corrupt_magic corrupt_payload corrupt_crc invalid_utf8 nul_text trailing_skippable trailing_frame; do
  hex=$(fixture_hex "test/fixtures/database_v1/${name}.mcdb")
  check "$name -> NULL" \
    "$(q "USE app; SELECT multi_compress_db_decompress(UNHEX('$hex')) IS NULL;")" \
    "1"
done
check "is_valid false (crc)" \
  "$(q "USE app; SELECT multi_compress_db_is_valid(UNHEX('$(fixture_hex test/fixtures/database_v1/corrupt_crc.mcdb)'));")" \
  "0"

docker exec -i "$CONTAINER" mysql < mysql_udf/sql/uninstall.sql
check_err "uninstall removes UDF" "SELECT multi_compress_db_version();"

if [ "$fails" -ne 0 ]; then echo "E2E FAILED ($fails)"; exit 1; fi
echo "E2E OK"
