SHELL := /bin/bash

# PG_CONFIG is the normal public override. It is used for both compilation and
# installation paths. BUILD_PG_CONFIG/RUNTIME_PG_CONFIG exist for uncommon
# containerised deployments where headers are installed separately from the
# running server; ordinary DBAs never need to set them.
PG_CONFIG ?=
BUILD_PG_CONFIG ?= $(PG_CONFIG)
RUNTIME_PG_CONFIG ?= $(PG_CONFIG)
DB ?=
SCHEMA ?= multi_compress
MIGRATION_ROLE ?=
READ_ROLE ?=
CONFIRM ?=

.PHONY: help verify doctor install enable uninstall

help:
	@printf '%s\n' \
	  'MultiCompress PostgreSQL deployment bundle' \
	  '' \
	  '  make verify' \
	  '  make doctor [PG_CONFIG=/path/to/pg_config]' \
	  '  sudo make install [PG_CONFIG=/path/to/pg_config]' \
	  '  sudo -u postgres make enable DB=app_production MIGRATION_ROLE=app_migrations READ_ROLE=dbeaver_readonly [SCHEMA=multi_compress]' \
	  '  sudo make uninstall CONFIRM=REMOVE_MULTI_COMPRESS [PG_CONFIG=/path/to/pg_config]'

verify:
	./bin/verify

doctor:
	./bin/doctor $(if $(BUILD_PG_CONFIG),--pg-config "$(BUILD_PG_CONFIG)")

install: verify
	./bin/install $(if $(BUILD_PG_CONFIG),--build-pg-config "$(BUILD_PG_CONFIG)") $(if $(RUNTIME_PG_CONFIG),--runtime-pg-config "$(RUNTIME_PG_CONFIG)")

enable:
	@test -n "$(DB)" || { echo 'DB is required: make enable DB=app_production' >&2; exit 2; }
	@test -n "$(MIGRATION_ROLE)" || { echo 'MIGRATION_ROLE is required: make enable ... MIGRATION_ROLE=app_migrations' >&2; exit 2; }
	@test -n "$(READ_ROLE)" || { echo 'READ_ROLE is required: make enable ... READ_ROLE=dbeaver_readonly' >&2; exit 2; }
	./bin/enable --database "$(DB)" --schema "$(SCHEMA)" --migration-role "$(MIGRATION_ROLE)" --read-role "$(READ_ROLE)"

uninstall:
	@test "$(CONFIRM)" = "REMOVE_MULTI_COMPRESS" || { echo 'uninstall requires CONFIRM=REMOVE_MULTI_COMPRESS' >&2; exit 2; }
	./bin/uninstall $(if $(RUNTIME_PG_CONFIG),--pg-config "$(RUNTIME_PG_CONFIG)")
