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

apply_dictionary_readable_view() {
  local path="$1"
  local warnings
  db_cli view mysql \
    --table app.dictionary_events \
    --column payload_compressed \
    --dictionary-table app.mcdb_dictionary_versions \
    --dictionary-id-column payload_dictionary_id \
    --view admin.dictionary_events_readable \
    --columns id \
    --output "$path"
  warnings=$( { cat "$path"; printf '\nSHOW WARNINGS;\n'; } | docker exec -i "$CONTAINER" mysql \
    --default-character-set=utf8mb4 --batch --skip-column-names --raw)
  if printf '%s\n' "$warnings" | grep -Eqi '(undefined|merge)'; then
    echo "MySQL refused the required MERGE view algorithm:" >&2
    printf '%s\n' "$warnings" >&2
    exit 1
  fi
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
VIEW_SQL="$(mktemp -t multi-compress-mysql-view.XXXXXX.sql)"
DICT_VIEW_SQL="$(mktemp -t multi-compress-mysql-dictionary-view.XXXXXX.sql)"
REGISTRY_SQL="$(mktemp -t multi-compress-mysql-registry.XXXXXX.sql)"
trap 'rm -f "$VIEW_SQL" "$DICT_VIEW_SQL" "$REGISTRY_SQL"; cleanup' EXIT

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

# MCDB2: registry DDL lives in app and the generated view supplies dictionary bytes through an INNER JOIN.
q "USE app;
   CREATE TABLE dictionary_events (
     id INT PRIMARY KEY,
     payload_compressed LONGBLOB NOT NULL,
     payload_dictionary_id BIGINT UNSIGNED NOT NULL
   ) ENGINE=InnoDB;"
db_cli registry mysql --database app \
  --payload-table dictionary_events --payload-column payload_compressed \
  --payload-dictionary-id-column payload_dictionary_id \
  --output "$REGISTRY_SQL"
docker exec -i "$CONTAINER" mysql --default-character-set=utf8mb4 < "$REGISTRY_SQL"
q "USE app;
   INSERT INTO mcdb_dictionary_versions (id, family, zstd_dict_id, sha256, bytes)
     VALUES ($DICT_REF, 'events_payload_v1', $DICT_ZSTD_ID, UNHEX('$DICT_SHA_HEX'), UNHEX('$DICT_HEX'));
   INSERT INTO dictionary_events (id, payload_compressed, payload_dictionary_id)
   SELECT seq.id, UNHEX('$DICT_BLOB_HEX'), $DICT_REF
   FROM (
     SELECT ones.n + tens.n * 10 + hundreds.n * 100 + 1 AS id
     FROM (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
           UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) AS ones
     CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) AS tens
     CROSS JOIN (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) AS hundreds
   ) AS seq
   WHERE seq.id <= 1000;"
apply_dictionary_readable_view "$DICT_VIEW_SQL"

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
check "MCDB2 dictionary reference" "$(q 'USE app; SELECT multi_compress_db_dictionary_ref(payload_compressed) FROM dictionary_events WHERE id=1;')" "$DICT_REF"
check "MCDB2 original size" "$(q 'USE app; SELECT multi_compress_db_original_size(payload_compressed) FROM dictionary_events WHERE id=1;')" "$TEXT_BYTES"
check "MCDB2 generated readable view" "$(q 'SELECT payload FROM admin.dictionary_events_readable WHERE id=1;')" "$TEXT"
check "MCDB2 dictionary is valid" \
  "$(q 'USE app; SELECT multi_compress_db_is_valid_dict(e.payload_compressed, e.payload_dictionary_id, d.sha256, d.bytes) FROM dictionary_events e JOIN mcdb_dictionary_versions d ON d.id = e.payload_dictionary_id WHERE e.id=1;')" \
  "1"
check_err "MCDB2 payload/FK mismatch rejected" "USE app; INSERT INTO dictionary_events VALUES (1001, UNHEX('$DICT_BLOB_HEX'), $((DICT_REF + 1)));"
check "MCDB2 rejects wrong dictionary digest" \
  "$(q 'USE app; SELECT multi_compress_db_is_valid_dict(e.payload_compressed, e.payload_dictionary_id, UNHEX(REPEAT("00", 32)), d.bytes) FROM dictionary_events e JOIN mcdb_dictionary_versions d ON d.id = e.payload_dictionary_id WHERE e.id=1;')" \
  "0"
MYSQL_DICT_PLAN="$(q 'EXPLAIN SELECT id, payload FROM admin.dictionary_events_readable WHERE id BETWEEN 100 AND 900 ORDER BY id LIMIT 100;')"
if printf '%s\n' "$MYSQL_DICT_PLAN" | grep -Fq '<derived'; then
  echo "  FAIL  MCDB2 view materialized as a derived table"
  printf '%s\n' "$MYSQL_DICT_PLAN" >&2
  fails=$((fails + 1))
elif ! printf '%s\n' "$MYSQL_DICT_PLAN" | awk -F '\t' '$3 == "source" && $5 == "range" && $7 == "PRIMARY" { found = 1 } END { exit(found ? 0 : 1) }'; then
  echo "  FAIL  MCDB2 view did not use the source PRIMARY range scan"
  printf '%s\n' "$MYSQL_DICT_PLAN" >&2
  fails=$((fails + 1))
else
  # `Using temporary` / `Using filesort` here belongs to the outer ORDER BY
  # over a joined projection. It is not evidence that the view was materialized:
  # MySQL reports materialized views as <derived...>. The important contract is
  # that the source predicate is merged and reaches the PRIMARY range scan.
  echo "  PASS  MCDB2 view is MERGE-able and keeps the source PRIMARY range scan"
fi
check "max_allowed_packet is reported" "$(q 'SELECT @@GLOBAL.max_allowed_packet > 0;')" "1"

MYSQL_SOCKET_PATH="$(q 'SELECT @@socket;' | tr -d '\r\n')"
# Simulate an installed 0.5.x server: only the three MCDB1 UDF registrations
# remain. 0.6 must recognise this as upgradeable, not partial, then use the
# documented DROP -> replace library -> CREATE lifecycle to register all nine.
docker exec -u 0 \
  -e "MCDB_BUNDLE_ROOT=${BUNDLE_PARENT}/${BUNDLE_NAME}" \
  -e "MCDB_MYSQL_SOCKET=$MYSQL_SOCKET_PATH" \
  "$CONTAINER" sh -ceu '
    mysql --protocol=SOCKET --socket="$MCDB_MYSQL_SOCKET" -e "
      DROP FUNCTION multi_compress_db_decompress_dict;
      DROP FUNCTION multi_compress_db_is_valid_dict;
      DROP FUNCTION multi_compress_db_dictionary_sha256;
      DROP FUNCTION multi_compress_db_dictionary_zstd_id;
      DROP FUNCTION multi_compress_db_dictionary_ref;
      DROP FUNCTION multi_compress_db_original_size;"
    cd "$MCDB_BUNDLE_ROOT"
    make status MYSQL_SOCKET="$MCDB_MYSQL_SOCKET" | grep -F "state: MCDB1-only"
    make doctor MYSQL_SOCKET="$MCDB_MYSQL_SOCKET" | grep -F "server socket: $MCDB_MYSQL_SOCKET"
    make upgrade CONFIRM=UPGRADE_MULTI_COMPRESS MYSQL_SOCKET="$MCDB_MYSQL_SOCKET"
    make status MYSQL_SOCKET="$MCDB_MYSQL_SOCKET" | grep -F "state: enabled"
  '
check "upgrade from MCDB1-only restores MCDB2 functions" "$(q 'SELECT multi_compress_db_original_size(payload_compressed) FROM app.dictionary_events WHERE id=1;')" "$TEXT_BYTES"
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
