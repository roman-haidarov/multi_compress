ZSTD_DIR      ?= ../ext/multi_compress/vendor/zstd/lib
CORE_DIR      ?= ../db_core
BUILD         ?= build
CC            ?= gcc
AR            ?= ar
MYSQL_UDF_ABI ?= mysql57
MYSQL_INCLUDE ?= /usr/include/mysql
FIXTURES      ?= ../test/fixtures/database_v1

ifeq ($(MYSQL_UDF_ABI),mysql57)
MYSQL_UDF_CPPFLAGS := -DMCDB_MYSQL_UDF_ABI_57
MYSQL_UDF_HEADER_CHECK :=
else ifeq ($(MYSQL_UDF_ABI),system)
MYSQL_UDF_CPPFLAGS := -I$(MYSQL_INCLUDE)
MYSQL_UDF_HEADER_CHECK := test -f "$(MYSQL_INCLUDE)/mysql.h" || { echo "missing mysql.h: set MYSQL_INCLUDE=/path/to/mysql/include" >&2; exit 2; }
else
$(error MYSQL_UDF_ABI must be mysql57 or system)
endif

WARNFLAGS     ?= -Wall -Wextra -Werror
CFLAGS        ?= -O2 -fPIC -std=c99 $(WARNFLAGS) -I$(ZSTD_DIR) -I$(CORE_DIR)/include
ZSTD_CFLAGS   ?= -O2 -fPIC -std=c99 -I$(ZSTD_DIR) -I$(ZSTD_DIR)/common

ZSTD_OBJ_DIR  := $(BUILD)/zstd
ZSTD_C_SRCS   := $(wildcard $(ZSTD_DIR)/common/*.c) $(wildcard $(ZSTD_DIR)/decompress/*.c)
ZSTD_C_OBJS   := $(patsubst $(ZSTD_DIR)/%.c,$(ZSTD_OBJ_DIR)/%.o,$(ZSTD_C_SRCS))

ARCH := $(shell uname -m)
ifneq (,$(filter x86_64 amd64,$(ARCH)))
ZSTD_ASM_SRC  := $(ZSTD_DIR)/decompress/huf_decompress_amd64.S
ifneq (,$(wildcard $(ZSTD_ASM_SRC)))
ZSTD_ASM_OBJ  := $(ZSTD_OBJ_DIR)/decompress/huf_decompress_amd64.o
endif
endif

ZSTD_OBJS     := $(ZSTD_C_OBJS) $(ZSTD_ASM_OBJ)
ZSTD_LIB      := $(BUILD)/libzstd_dec.a
UDF_SO        := $(BUILD)/multi_compress_mysql.so
CLI           := $(BUILD)/mcdb_cli
VALID_FIXTURES   := utf8_text empty_text large_text
CORRUPT_FIXTURES := corrupt_magic wrong_version corrupt_payload corrupt_crc invalid_utf8 nul_text trailing_skippable trailing_frame

.PHONY: all udf test fixtures clean
all: udf

$(BUILD):
	mkdir -p $@

$(ZSTD_OBJ_DIR)/%.o: $(ZSTD_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(ZSTD_CFLAGS) -MMD -MP -c $< -o $@

$(ZSTD_OBJ_DIR)/%.o: $(ZSTD_DIR)/%.S
	@mkdir -p $(dir $@)
	$(CC) -fPIC -I$(ZSTD_DIR) -c $< -o $@

$(ZSTD_LIB): $(ZSTD_OBJS) | $(BUILD)
	$(AR) rcs $@ $^

$(UDF_SO): src/multi_compress_mysql.c $(CORE_DIR)/src/mcdb_format.c $(CORE_DIR)/include/mcdb_format.h $(ZSTD_LIB) | $(BUILD)
	@$(MYSQL_UDF_HEADER_CHECK)
	$(CC) $(CFLAGS) $(MYSQL_UDF_CPPFLAGS) -shared \
	  src/multi_compress_mysql.c $(CORE_DIR)/src/mcdb_format.c $(ZSTD_LIB) \
	  -o $@
	@echo "built $@"

udf: $(UDF_SO)

$(CLI): $(CORE_DIR)/src/mcdb_format.c $(CORE_DIR)/include/mcdb_format.h test/mcdb_cli.c $(ZSTD_LIB) | $(BUILD)
	$(CC) $(CFLAGS) $(CORE_DIR)/src/mcdb_format.c test/mcdb_cli.c $(ZSTD_LIB) -o $@

fixtures:
	RUBYLIB=../lib ruby $(FIXTURES)/generate.rb

test: $(CLI)
	@echo "== MCDB1 Ruby<->C parity =="
	@fail=0; \
	for name in $(VALID_FIXTURES); do \
	  f=$(FIXTURES)/$$name.mcdb; exp=$(FIXTURES)/$$name.expected; \
	  if [ ! -f $$f ] || [ ! -f $$exp ]; then echo "  MISSING $$name (run: make fixtures)"; fail=1; continue; fi; \
	  if $(CLI) decode $$f | cmp -s - $$exp; then echo "  valid   $$name  OK"; \
	  else echo "  valid   $$name  FAIL"; fail=1; fi; \
	done; \
	for name in $(CORRUPT_FIXTURES); do \
	  f=$(FIXTURES)/$$name.mcdb; \
	  if [ ! -f $$f ]; then echo "  MISSING $$name (run: make fixtures)"; fail=1; continue; fi; \
	  if $(CLI) decode $$f >/dev/null 2>&1; then echo "  corrupt $$name  UNEXPECTEDLY VALID"; fail=1; \
	  else echo "  corrupt $$name  correctly rejected"; fi; \
	done; \
	if [ $$fail -ne 0 ]; then echo "PARITY FAILED"; exit 1; fi; \
	echo "PARITY OK"

clean:
	rm -rf $(BUILD)

-include $(ZSTD_C_OBJS:.o=.d)
