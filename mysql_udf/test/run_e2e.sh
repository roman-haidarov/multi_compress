#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

DEFAULT_MYSQL_IMAGE="mysql:5.7.44@sha256:dab0a802b44617303694fb17d166501de279c3031ddeb28c56ecf7fcab5ef0da"
IMAGE="${MCDB_MYSQL_IMAGE:-$DEFAULT_MYSQL_IMAGE}"
PLATFORM="${MCDB_MYSQL_PLATFORM:-linux/amd64}"
CONTAINER="${MCDB_MYSQL_CONTAINER:-mcdb-e2e}"
WAIT_SECONDS="${MCDB_MYSQL_WAIT_SECONDS:-90}"
WORK_ROOT="${MCDB_MYSQL_WORK_ROOT:-$(mktemp -d -t multi-compress-mysql.XXXXXX)}"
REMOVE_WORK_ROOT=0
ARCHIVE="$WORK_ROOT/multi_compress-mysql.tar.gz"
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

if [ -z "${MCDB_MYSQL_WORK_ROOT:-}" ]; then
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

bundle_name() {
  ruby -I "$PACKAGED_GEM_ROOT/lib" -r multi_compress/version \
    -e 'print "multi_compress-mysql-#{MultiCompress::VERSION}"'
}

build_deployment_bundle() {
  db_cli package mysql --output "$ARCHIVE" --force
  test -s "$ARCHIVE"
}

install_mysql_build_tools() {
  docker exec -u 0 "$CONTAINER" sh -ceu '
    if command -v yum >/dev/null 2>&1; then
      yum install -y gcc make binutils tar gzip
    elif command -v microdnf >/dev/null 2>&1; then
      microdnf install -y gcc make binutils tar gzip
    elif command -v apt-get >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential tar gzip
    else
      echo "no supported package manager in MySQL container" >&2
      exit 2
    fi

    command -v cc
    command -v make
    command -v ar
  '
}

install_bundle_on_db_host() {
  local bundle_name="$1"
  local bundle_root="${BUNDLE_PARENT}/${bundle_name}"

  tar -tzf "$ARCHIVE" | grep -Fx "${bundle_name}/THIRD_PARTY_NOTICES.md" >/dev/null
  if tar -tzf "$ARCHIVE" | grep -E '/\.DS_Store$' >/dev/null; then
    echo 'deployment bundle must not contain .DS_Store' >&2
    exit 2
  fi
  docker cp "$ARCHIVE" "$CONTAINER:/tmp/${bundle_name}.tar.gz"
  docker exec -u 0 -e "MCDB_BUNDLE_ROOT=$bundle_root" "$CONTAINER" sh -ceu '
    rm -rf "$MCDB_BUNDLE_ROOT"
    mkdir -p "$(dirname "$MCDB_BUNDLE_ROOT")"
    tar -xzf "/tmp/$(basename "$MCDB_BUNDLE_ROOT").tar.gz" -C "$(dirname "$MCDB_BUNDLE_ROOT")"
    cd "$MCDB_BUNDLE_ROOT"
    make verify
    make doctor
    make install
    make enable
    make status
  '
}

apply_readable_view() {
  local path="$1"
  db_cli view mysql \
    --table app.events \
    --column payload_compressed \
    --view admin.events_readable \
    --columns id \
    --output "$path"
  docker exec -i "$CONTAINER" mysql --default-character-set=utf8mb4 < "$path"
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
CORRUPT_HEX=$(fixture_hex test/fixtures/database_v1/corrupt_crc.mcdb)
BUNDLE_NAME="$(bundle_name)"
VIEW_SQL="$(mktemp -t multi-compress-mysql-view.XXXXXX.sql)"
trap 'rm -f "$VIEW_SQL"; cleanup' EXIT

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

install_mysql_build_tools
install_bundle_on_db_host "$BUNDLE_NAME"

q "DROP DATABASE IF EXISTS app;
   DROP DATABASE IF EXISTS admin;
   CREATE DATABASE app CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   CREATE DATABASE admin CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
   USE app;
   CREATE TABLE events (id INT PRIMARY KEY, payload_compressed LONGBLOB NULL);
   INSERT INTO events VALUES
     (1, UNHEX('$VALID_HEX')),
     (2, NULL),
     (3, UNHEX('$BIG_HEX')),
     (4, UNHEX('$VALID_HEX')),
     (5, UNHEX('$CORRUPT_HEX')),
     (6, UNHEX('$VALID_HEX'));"
apply_readable_view "$VIEW_SQL"

fails=0
check() {
  if [ "$2" = "$3" ]; then echo "  PASS  $1"; else echo "  FAIL  $1 (got [$2] want [$3])"; fails=$((fails + 1)); fi
}
check_err() {
  if qfail "$2"; then echo "  PASS  $1 (rejected)"; else echo "  FAIL  $1 (should have errored)"; fails=$((fails + 1)); fi
}

check "deployment bundle version() smoke" "$(q 'SELECT LOCATE(CHAR(77,67,68,66,49), multi_compress_db_version()) > 0;')" "1"
check "MySQL connection uses utf8mb4" \
  "$(q "SELECT CONCAT(@@character_set_client, '/', @@character_set_connection, '/', @@character_set_results);")" \
  "utf8mb4/utf8mb4/utf8mb4"
check "decode roundtrip" \
  "$(q 'USE app; SELECT CONVERT(multi_compress_db_decompress(payload_compressed) USING utf8mb4) FROM events WHERE id=1;')" \
  "$TEXT"
check "NULL -> NULL" "$(q 'USE app; SELECT multi_compress_db_decompress(payload_compressed) IS NULL FROM events WHERE id=2;')" "1"
check "big (>255, >input)" "$(q 'USE app; SELECT OCTET_LENGTH(multi_compress_db_decompress(payload_compressed)) FROM events WHERE id=3;')" "300"
check "generated readable view" "$(q 'SELECT COUNT(*) FROM admin.events_readable WHERE id IN (1, 4);')" "2"
check "generated readable view returns Unicode" \
  "$(q 'SELECT payload FROM admin.events_readable WHERE id=1;')" \
  "$TEXT"
check "valid-corrupt-valid scan preserves later valid row" \
  "$(q "USE app; SELECT GROUP_CONCAT(CASE WHEN multi_compress_db_decompress(payload_compressed) IS NULL THEN '<NULL>' ELSE CONVERT(multi_compress_db_decompress(payload_compressed) USING utf8mb4) END ORDER BY id SEPARATOR '|') FROM events WHERE id IN (1, 5, 6);")" \
  "$TEXT|<NULL>|$TEXT"
check "is_valid true" "$(q 'USE app; SELECT multi_compress_db_is_valid(payload_compressed) FROM events WHERE id=1;')" "1"
check "is_valid on NULL" "$(q 'USE app; SELECT multi_compress_db_is_valid(payload_compressed) IS NULL FROM events WHERE id=2;')" "1"

for name in corrupt_magic corrupt_payload corrupt_crc invalid_utf8 nul_text trailing_skippable trailing_frame; do
  hex=$(fixture_hex "test/fixtures/database_v1/${name}.mcdb")
  check "$name -> NULL" \
    "$(q "USE app; SELECT multi_compress_db_decompress(UNHEX('$hex')) IS NULL;")" \
    "1"
done
check "is_valid false (crc)" \
  "$(q "SELECT multi_compress_db_is_valid(UNHEX('$(fixture_hex test/fixtures/database_v1/corrupt_crc.mcdb)'));")" \
  "0"
check "max_allowed_packet is reported" "$(q 'SELECT @@GLOBAL.max_allowed_packet > 0;')" "1"

MYSQL_SOCKET_PATH="$(q 'SELECT @@socket;' | tr -d '\r\n')"
docker exec -u 0 \
  -e "MCDB_BUNDLE_ROOT=${BUNDLE_PARENT}/${BUNDLE_NAME}" \
  -e "MCDB_MYSQL_SOCKET=$MYSQL_SOCKET_PATH" \
  "$CONTAINER" sh -ceu '
    cd "$MCDB_BUNDLE_ROOT"
    make doctor MYSQL_SOCKET="$MCDB_MYSQL_SOCKET" | grep -F "server socket: $MCDB_MYSQL_SOCKET"
    make upgrade CONFIRM=UPGRADE_MULTI_COMPRESS MYSQL_SOCKET="$MCDB_MYSQL_SOCKET"
    make status MYSQL_SOCKET="$MCDB_MYSQL_SOCKET" | grep -F "state: enabled"
  '
check "upgrade keeps version() available" "$(q 'SELECT LOCATE(CHAR(77,67,68,66,49), multi_compress_db_version()) > 0;')" "1"

# Register one expected name to a different SONAME and prove enable refuses without
# dropping it. The copied library makes this a real MySQL registration, not a mock.
docker exec -u 0 \
  -e "MCDB_BUNDLE_ROOT=${BUNDLE_PARENT}/${BUNDLE_NAME}" \
  -e "MCDB_MYSQL_SOCKET=$MYSQL_SOCKET_PATH" \
  "$CONTAINER" sh -ceu '
    plugin_dir="$(mysql --protocol=SOCKET --socket="$MCDB_MYSQL_SOCKET" --batch --skip-column-names -e "SELECT @@plugin_dir;")"
    mysql --protocol=SOCKET --socket="$MCDB_MYSQL_SOCKET" -e "DROP FUNCTION multi_compress_db_version;"
    cp "$plugin_dir/multi_compress_mysql.so" "$plugin_dir/foreign_multi_compress.so"
    foreign_soname="$(printf "\\047foreign_multi_compress.so\\047")"
    mysql --protocol=SOCKET --socket="$MCDB_MYSQL_SOCKET" -e "CREATE FUNCTION multi_compress_db_version RETURNS STRING SONAME $foreign_soname;"
    cd "$MCDB_BUNDLE_ROOT"
    if make enable MYSQL_SOCKET="$MCDB_MYSQL_SOCKET" >/tmp/mcdb-foreign-enable.out 2>&1; then
      echo "enable unexpectedly accepted a foreign registration" >&2
      exit 1
    fi
    grep -F "foreign SONAME" /tmp/mcdb-foreign-enable.out
    mysql --protocol=SOCKET --socket="$MCDB_MYSQL_SOCKET" --batch --skip-column-names \
      -e "SELECT dl FROM mysql.func WHERE name = $(printf "\\047multi_compress_db_version\\047");" | grep -Fx "foreign_multi_compress.so"
    mysql --protocol=SOCKET --socket="$MCDB_MYSQL_SOCKET" -e "DROP FUNCTION multi_compress_db_version;"
    owned_soname="$(printf "\\047multi_compress_mysql.so\\047")"
    mysql --protocol=SOCKET --socket="$MCDB_MYSQL_SOCKET" -e "CREATE FUNCTION multi_compress_db_version RETURNS STRING SONAME $owned_soname;"
    rm -f "$plugin_dir/foreign_multi_compress.so"
  '

docker exec -u 0 -e "MCDB_BUNDLE_ROOT=${BUNDLE_PARENT}/${BUNDLE_NAME}" "$CONTAINER" sh -ceu '
  cd "$MCDB_BUNDLE_ROOT"
  if make disable >/dev/null 2>&1; then
    echo "disable succeeded without CONFIRM" >&2
    exit 1
  fi
  if make uninstall >/dev/null 2>&1; then
    echo "uninstall succeeded without CONFIRM" >&2
    exit 1
  fi
  make enable | grep -F "already enabled; no changes made."
  make uninstall CONFIRM=REMOVE_MULTI_COMPRESS
'
check_err "uninstall removes UDF" "SELECT multi_compress_db_version();"

if [ "$fails" -ne 0 ]; then echo "E2E FAILED ($fails)"; exit 1; fi
echo "E2E OK"
