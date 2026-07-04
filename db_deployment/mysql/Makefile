SHELL := /bin/bash

MYSQL ?= mysql
MYSQL_DEFAULTS_FILE ?=
MYSQL_SOCKET ?=
CONFIRM ?=

.PHONY: help verify doctor status install enable upgrade disable uninstall

help:
	@printf '%s\n' \
	  'MultiCompress MySQL 5.7 deployment bundle' \
	  '' \
	  '  make verify' \
	  '  make doctor [MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf] [MYSQL_SOCKET=/run/mysqld/mysqld.sock]' \
	  '  make status [MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf] [MYSQL_SOCKET=/run/mysqld/mysqld.sock]' \
	  '  sudo make install [MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf] [MYSQL_SOCKET=/run/mysqld/mysqld.sock]' \
	  '  make enable [MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf] [MYSQL_SOCKET=/run/mysqld/mysqld.sock]' \
	  '  sudo make upgrade CONFIRM=UPGRADE_MULTI_COMPRESS [MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf] [MYSQL_SOCKET=/run/mysqld/mysqld.sock]' \
	  '  make disable CONFIRM=DISABLE_MULTI_COMPRESS [MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf] [MYSQL_SOCKET=/run/mysqld/mysqld.sock]' \
	  '  sudo make uninstall CONFIRM=REMOVE_MULTI_COMPRESS [MYSQL_DEFAULTS_FILE=/etc/mysql/admin.cnf] [MYSQL_SOCKET=/run/mysqld/mysqld.sock]'

verify:
	./bin/verify

doctor:
	MYSQL_SOCKET="$(MYSQL_SOCKET)" ./bin/doctor --mysql "$(MYSQL)" $(if $(MYSQL_DEFAULTS_FILE),--defaults-extra-file "$(MYSQL_DEFAULTS_FILE)")

status:
	MYSQL_SOCKET="$(MYSQL_SOCKET)" ./bin/status --mysql "$(MYSQL)" $(if $(MYSQL_DEFAULTS_FILE),--defaults-extra-file "$(MYSQL_DEFAULTS_FILE)")

install: verify
	MYSQL_SOCKET="$(MYSQL_SOCKET)" ./bin/install --mysql "$(MYSQL)" $(if $(MYSQL_DEFAULTS_FILE),--defaults-extra-file "$(MYSQL_DEFAULTS_FILE)")

enable:
	MYSQL_SOCKET="$(MYSQL_SOCKET)" ./bin/enable --mysql "$(MYSQL)" $(if $(MYSQL_DEFAULTS_FILE),--defaults-extra-file "$(MYSQL_DEFAULTS_FILE)")

upgrade:
	@test "$(CONFIRM)" = "UPGRADE_MULTI_COMPRESS" || { echo 'upgrade requires CONFIRM=UPGRADE_MULTI_COMPRESS' >&2; exit 2; }
	MYSQL_SOCKET="$(MYSQL_SOCKET)" ./bin/upgrade --mysql "$(MYSQL)" $(if $(MYSQL_DEFAULTS_FILE),--defaults-extra-file "$(MYSQL_DEFAULTS_FILE)")

disable:
	@test "$(CONFIRM)" = "DISABLE_MULTI_COMPRESS" || { echo 'disable requires CONFIRM=DISABLE_MULTI_COMPRESS' >&2; exit 2; }
	MYSQL_SOCKET="$(MYSQL_SOCKET)" ./bin/disable --mysql "$(MYSQL)" $(if $(MYSQL_DEFAULTS_FILE),--defaults-extra-file "$(MYSQL_DEFAULTS_FILE)")

uninstall:
	@test "$(CONFIRM)" = "REMOVE_MULTI_COMPRESS" || { echo 'uninstall requires CONFIRM=REMOVE_MULTI_COMPRESS' >&2; exit 2; }
	MYSQL_SOCKET="$(MYSQL_SOCKET)" ./bin/uninstall --mysql "$(MYSQL)" $(if $(MYSQL_DEFAULTS_FILE),--defaults-extra-file "$(MYSQL_DEFAULTS_FILE)")
