EXTENSION   = multi_compress
MODULE_big  = multi_compress_pg
OBJS        = src/multi_compress_pg.o src/mcdb_format.o
DATA        = sql/multi_compress--0.5.0.sql sql/multi_compress--0.6.0.sql sql/multi_compress--0.5.0--0.6.0.sql

PG_CONFIG   ?= pg_config
ZSTD_DIR    ?= ../ext/multi_compress/vendor/zstd/lib
CORE_DIR    ?= ../db_core
BUILD       ?= build
CC          ?= cc
AR          ?= ar

WARNFLAGS   ?= -Wall -Wextra -Werror
PG_CPPFLAGS += -I$(CORE_DIR)/include -I$(ZSTD_DIR)
PG_CFLAGS   += -O2 -fPIC -std=c99 $(WARNFLAGS)
EXPORT_MAP  := $(CURDIR)/multi_compress_pg.exports
SHLIB_LINK  += -Wl,--version-script=$(EXPORT_MAP) $(ZSTD_LIB)
EXTRA_CLEAN += $(BUILD)

ZSTD_CFLAGS  ?= -O2 -fPIC -std=c99 -I$(ZSTD_DIR) -I$(ZSTD_DIR)/common
ZSTD_OBJ_DIR := $(BUILD)/zstd
ZSTD_C_SRCS  := $(wildcard $(ZSTD_DIR)/common/*.c) $(wildcard $(ZSTD_DIR)/decompress/*.c)
ZSTD_C_OBJS  := $(patsubst $(ZSTD_DIR)/%.c,$(ZSTD_OBJ_DIR)/%.o,$(ZSTD_C_SRCS))

ARCH := $(shell uname -m)
ifneq (,$(filter x86_64 amd64,$(ARCH)))
ZSTD_ASM_SRC := $(ZSTD_DIR)/decompress/huf_decompress_amd64.S
ifneq (,$(wildcard $(ZSTD_ASM_SRC)))
ZSTD_ASM_OBJ := $(ZSTD_OBJ_DIR)/decompress/huf_decompress_amd64.o
endif
endif

ZSTD_OBJS := $(ZSTD_C_OBJS) $(ZSTD_ASM_OBJ)
ZSTD_LIB  := $(BUILD)/libzstd_dec.a

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

.PHONY: all test parity e2e fixtures

all: $(ZSTD_LIB)

$(MODULE_big)$(DLSUFFIX): $(ZSTD_LIB)

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

# The source wrapper includes the shared MCDB1/MCDB2 decoder; it is not a fork.
src/mcdb_format.o: src/mcdb_format.c $(CORE_DIR)/src/mcdb_format.c $(CORE_DIR)/include/mcdb_format.h

# Golden fixtures are committed. Regeneration is a development action only.
fixtures:
	RUBYLIB=../lib ruby ../test/fixtures/database_v1/generate.rb

parity:
	$(MAKE) -C ../mysql_udf test

test: all parity

e2e:
	./test/run_e2e.sh

-include $(ZSTD_C_OBJS:.o=.d)
