#include "postgres.h"

#include "fmgr.h"
#include "mb/pg_wchar.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "varatt.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zstd.h>

#include "mcdb_format.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(multi_compress_db_version);
PG_FUNCTION_INFO_V1(multi_compress_db_is_valid);
PG_FUNCTION_INFO_V1(multi_compress_db_decompress);
PG_FUNCTION_INFO_V1(multi_compress_db_original_size);
PG_FUNCTION_INFO_V1(multi_compress_db_dictionary_ref);
PG_FUNCTION_INFO_V1(multi_compress_db_dictionary_zstd_id);
PG_FUNCTION_INFO_V1(multi_compress_db_dictionary_sha256);
PG_FUNCTION_INFO_V1(multi_compress_db_is_valid_dict);
PG_FUNCTION_INFO_V1(multi_compress_db_decompress_dict);

#define MCDB_PG_DDICT_CACHE_ENTRIES 4

typedef struct {
    uint64_t dictionary_ref;
    unsigned char sha256[MCDB_SHA256_BYTES];
    unsigned char *bytes;
    size_t bytes_len;
    ZSTD_DDict *ddict;
    uint64_t used_at;
} mcdb_pg_cache_entry;

typedef struct {
    ZSTD_DCtx *dctx;
    uint64_t clock;
    mcdb_pg_cache_entry entries[MCDB_PG_DDICT_CACHE_ENTRIES];
} mcdb_pg_dictionary_cache;

static void mcdb_require_utf8_database(void) {
    if (GetDatabaseEncoding() != PG_UTF8)
        ereport(
            ERROR,
            (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
             errmsg("multi_compress requires a UTF-8 PostgreSQL database"),
             errdetail("MCDB stores UTF-8 text and multi_compress_db_decompress returns text.")));
}

static void mcdb_raise(mcdb_status status, const char *detail) {
    if (status == MCDB_ERR_ALLOC)
        ereport(ERROR, (errcode(ERRCODE_OUT_OF_MEMORY),
                        errmsg("multi_compress: unable to allocate MCDB output")));

    ereport(ERROR,
            (errcode(ERRCODE_DATA_CORRUPTED), errmsg("multi_compress: invalid MCDB envelope"),
             errdetail("%s", detail && detail[0] ? detail : mcdb_status_str(status))));
}

static void mcdb_raise_dictionary(const char *detail) {
    ereport(ERROR, (errcode(ERRCODE_DATA_CORRUPTED),
                    errmsg("multi_compress: invalid MCDB2 dictionary"), errdetail("%s", detail)));
}

static void mcdb_pg_cache_release(void *arg) {
    mcdb_pg_dictionary_cache *cache = (mcdb_pg_dictionary_cache *)arg;
    int i;

    if (cache == NULL)
        return;
    for (i = 0; i < MCDB_PG_DDICT_CACHE_ENTRIES; i++) {
        if (cache->entries[i].ddict)
            ZSTD_freeDDict(cache->entries[i].ddict);
    }
    if (cache->dctx)
        ZSTD_freeDCtx(cache->dctx);
}

static mcdb_pg_dictionary_cache *mcdb_pg_cache(FunctionCallInfo fcinfo) {
    FmgrInfo *flinfo = fcinfo->flinfo;
    mcdb_pg_dictionary_cache *cache;
    MemoryContext oldcontext;

    if (flinfo->fn_extra)
        return (mcdb_pg_dictionary_cache *)flinfo->fn_extra;

    oldcontext = MemoryContextSwitchTo(flinfo->fn_mcxt);
    cache = (mcdb_pg_dictionary_cache *)palloc0(sizeof(*cache));
    cache->dctx = ZSTD_createDCtx();
    if (!cache->dctx) {
        MemoryContextSwitchTo(oldcontext);
        ereport(ERROR, (errcode(ERRCODE_OUT_OF_MEMORY),
                        errmsg("multi_compress: unable to allocate zstd context")));
    }
    {
        MemoryContextCallback *callback = (MemoryContextCallback *)palloc0(sizeof(*callback));
        callback->func = mcdb_pg_cache_release;
        callback->arg = cache;
        MemoryContextRegisterResetCallback(flinfo->fn_mcxt, callback);
    }
    flinfo->fn_extra = cache;
    MemoryContextSwitchTo(oldcontext);
    return cache;
}

static int mcdb_pg_cache_victim(mcdb_pg_dictionary_cache *cache, int same_key) {
    int i;
    int victim = 0;
    uint64_t oldest = UINT64_MAX;

    if (same_key >= 0)
        return same_key;
    for (i = 0; i < MCDB_PG_DDICT_CACHE_ENTRIES; i++) {
        if (!cache->entries[i].ddict)
            return i;
        if (cache->entries[i].used_at < oldest) {
            oldest = cache->entries[i].used_at;
            victim = i;
        }
    }
    return victim;
}

static ZSTD_DDict *mcdb_pg_cached_ddict(FunctionCallInfo fcinfo, int64 dictionary_ref,
                                        const unsigned char *dictionary_sha256,
                                        const unsigned char *dictionary, size_t dictionary_len,
                                        char *errbuf, mcdb_status *out_status) {
    mcdb_pg_dictionary_cache *cache = mcdb_pg_cache(fcinfo);
    unsigned char actual_sha256[MCDB_SHA256_BYTES];
    int i;
    int same_key = -1;
    int victim;
    ZSTD_DDict *ddict;
    MemoryContext oldcontext;

    *out_status = MCDB_OK;
    for (i = 0; i < MCDB_PG_DDICT_CACHE_ENTRIES; i++) {
        mcdb_pg_cache_entry *entry = &cache->entries[i];
        if (!entry->ddict || entry->dictionary_ref != (uint64_t)dictionary_ref ||
            memcmp(entry->sha256, dictionary_sha256, MCDB_SHA256_BYTES) != 0)
            continue;
        same_key = i;
        if (entry->bytes_len == dictionary_len &&
            memcmp(entry->bytes, dictionary, dictionary_len) == 0) {
            entry->used_at = ++cache->clock;
            return entry->ddict;
        }
        break;
    }

    mcdb_sha256(dictionary, dictionary_len, actual_sha256);
    if (memcmp(actual_sha256, dictionary_sha256, MCDB_SHA256_BYTES) != 0) {
        snprintf(errbuf, MCDB_ERRLEN, "dictionary sha256 does not match dictionary bytes");
        *out_status = MCDB_ERR_DICTIONARY_ID;
        return NULL;
    }
    *out_status = mcdb_validate_dictionary(dictionary, dictionary_len, NULL);
    if (*out_status != MCDB_OK) {
        snprintf(errbuf, MCDB_ERRLEN,
                 "dictionary is not a conformant zstd dictionary with a non-zero DictID");
        return NULL;
    }

    ddict = ZSTD_createDDict(dictionary, dictionary_len);
    if (!ddict) {
        *out_status = MCDB_ERR_ALLOC;
        return NULL;
    }

    victim = mcdb_pg_cache_victim(cache, same_key);
    if (cache->entries[victim].ddict)
        ZSTD_freeDDict(cache->entries[victim].ddict);
    if (cache->entries[victim].bytes)
        pfree(cache->entries[victim].bytes);

    oldcontext = MemoryContextSwitchTo(fcinfo->flinfo->fn_mcxt);
    cache->entries[victim].bytes = (unsigned char *)palloc(dictionary_len);
    memcpy(cache->entries[victim].bytes, dictionary, dictionary_len);
    MemoryContextSwitchTo(oldcontext);
    cache->entries[victim].dictionary_ref = (uint64_t)dictionary_ref;
    memcpy(cache->entries[victim].sha256, dictionary_sha256, MCDB_SHA256_BYTES);
    cache->entries[victim].bytes_len = dictionary_len;
    cache->entries[victim].ddict = ddict;
    cache->entries[victim].used_at = ++cache->clock;
    return ddict;
}

static bytea *mcdb_bytea_sha256(const unsigned char *bytes, size_t bytes_len) {
    bytea *result = (bytea *)palloc(VARHDRSZ + MCDB_SHA256_BYTES);
    mcdb_sha256(bytes, bytes_len, (unsigned char *)VARDATA(result));
    SET_VARSIZE(result, VARHDRSZ + MCDB_SHA256_BYTES);
    return result;
}

Datum multi_compress_db_version(PG_FUNCTION_ARGS) {
    char version[96];
    (void)fcinfo;
    snprintf(version, sizeof(version), "multi_compress reader %s; MCDB1 + MCDB2; zstd %s",
             MCDB_READER_VERSION, ZSTD_versionString());
    PG_RETURN_TEXT_P(cstring_to_text(version));
}

Datum multi_compress_db_is_valid(PG_FUNCTION_ARGS) {
    bytea *input;
    char err[MCDB_ERRLEN];
    mcdb_status status;
    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();
    input = PG_GETARG_BYTEA_PP(0);
    status = mcdb_decode((const unsigned char *)VARDATA_ANY(input),
                         (size_t)VARSIZE_ANY_EXHDR(input), NULL, NULL, err);
    PG_RETURN_BOOL(status == MCDB_OK);
}

Datum multi_compress_db_decompress(PG_FUNCTION_ARGS) {
    bytea *input;
    size_t output_len = 0;
    char err[MCDB_ERRLEN];
    mcdb_status status;
    uint64_t original_size = 0;
    text *result;
    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();
    mcdb_require_utf8_database();
    input = PG_GETARG_BYTEA_PP(0);
    status = mcdb_validate_header((const unsigned char *)VARDATA_ANY(input),
                                  (size_t)VARSIZE_ANY_EXHDR(input), &original_size);
    if (status != MCDB_OK)
        mcdb_raise(status, mcdb_status_str(status));
    result = (text *)palloc(VARHDRSZ + (size_t)original_size);
    status = mcdb_decode_into((const unsigned char *)VARDATA_ANY(input),
                              (size_t)VARSIZE_ANY_EXHDR(input), (unsigned char *)VARDATA(result),
                              (size_t)original_size, &output_len, err);
    if (status != MCDB_OK)
        mcdb_raise(status, err);
    SET_VARSIZE(result, VARHDRSZ + output_len);
    PG_RETURN_TEXT_P(result);
}

Datum multi_compress_db_original_size(PG_FUNCTION_ARGS) {
    bytea *input;
    mcdb_header header;
    mcdb_status status;
    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();
    input = PG_GETARG_BYTEA_PP(0);
    status = mcdb_parse_header((const unsigned char *)VARDATA_ANY(input),
                               (size_t)VARSIZE_ANY_EXHDR(input), &header);
    if (status != MCDB_OK)
        mcdb_raise(status, mcdb_status_str(status));
    PG_RETURN_INT64((int64)header.original_size);
}

Datum multi_compress_db_dictionary_ref(PG_FUNCTION_ARGS) {
    bytea *input;
    uint64_t ref;
    mcdb_status status;
    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();
    input = PG_GETARG_BYTEA_PP(0);
    ref = mcdb_dictionary_ref((const unsigned char *)VARDATA_ANY(input),
                              (size_t)VARSIZE_ANY_EXHDR(input), &status);
    if (status != MCDB_OK)
        mcdb_raise(status, mcdb_status_str(status));
    PG_RETURN_INT64((int64)ref);
}

Datum multi_compress_db_dictionary_zstd_id(PG_FUNCTION_ARGS) {
    bytea *dictionary;
    uint32_t dict_id;
    mcdb_status status;
    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();
    dictionary = PG_GETARG_BYTEA_PP(0);
    status = mcdb_validate_dictionary((const unsigned char *)VARDATA_ANY(dictionary),
                                      (size_t)VARSIZE_ANY_EXHDR(dictionary), &dict_id);
    if (status != MCDB_OK)
        mcdb_raise_dictionary(mcdb_status_str(status));
    PG_RETURN_INT64((int64)dict_id);
}

Datum multi_compress_db_dictionary_sha256(PG_FUNCTION_ARGS) {
    bytea *dictionary;
    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();
    dictionary = PG_GETARG_BYTEA_PP(0);
    PG_RETURN_BYTEA_P(mcdb_bytea_sha256((const unsigned char *)VARDATA_ANY(dictionary),
                                        (size_t)VARSIZE_ANY_EXHDR(dictionary)));
}

Datum multi_compress_db_is_valid_dict(PG_FUNCTION_ARGS) {
    bytea *input;
    int64 dictionary_ref;
    bytea *dictionary_sha256;
    bytea *dictionary;
    ZSTD_DDict *ddict;
    char err[MCDB_ERRLEN];
    mcdb_status status;
    uint64_t original_size;
    unsigned char *output;
    size_t output_len;

    if (PG_ARGISNULL(0) || PG_ARGISNULL(1) || PG_ARGISNULL(2) || PG_ARGISNULL(3))
        PG_RETURN_NULL();
    dictionary_ref = PG_GETARG_INT64(1);
    if (dictionary_ref <= 0)
        PG_RETURN_BOOL(false);
    dictionary_sha256 = PG_GETARG_BYTEA_PP(2);
    if (VARSIZE_ANY_EXHDR(dictionary_sha256) != MCDB_SHA256_BYTES)
        PG_RETURN_BOOL(false);
    input = PG_GETARG_BYTEA_PP(0);
    dictionary = PG_GETARG_BYTEA_PP(3);
    ddict = mcdb_pg_cached_ddict(fcinfo, dictionary_ref,
                                 (const unsigned char *)VARDATA_ANY(dictionary_sha256),
                                 (const unsigned char *)VARDATA_ANY(dictionary),
                                 (size_t)VARSIZE_ANY_EXHDR(dictionary), err, &status);
    if (!ddict || status != MCDB_OK)
        PG_RETURN_BOOL(false);
    status = mcdb_validate_v2_header((const unsigned char *)VARDATA_ANY(input),
                                     (size_t)VARSIZE_ANY_EXHDR(input), &original_size, NULL);
    if (status != MCDB_OK)
        PG_RETURN_BOOL(false);
    output = (unsigned char *)palloc((size_t)original_size ? (size_t)original_size : 1);
    status = mcdb_decode_v2_into((const unsigned char *)VARDATA_ANY(input),
                                 (size_t)VARSIZE_ANY_EXHDR(input), (uint64_t)dictionary_ref,
                                 (const unsigned char *)VARDATA_ANY(dictionary),
                                 (size_t)VARSIZE_ANY_EXHDR(dictionary), mcdb_pg_cache(fcinfo)->dctx,
                                 ddict, output, (size_t)original_size, &output_len, err);
    pfree(output);
    PG_RETURN_BOOL(status == MCDB_OK);
}

Datum multi_compress_db_decompress_dict(PG_FUNCTION_ARGS) {
    bytea *input;
    int64 dictionary_ref;
    bytea *dictionary_sha256;
    bytea *dictionary;
    ZSTD_DDict *ddict;
    char err[MCDB_ERRLEN];
    mcdb_status status;
    uint64_t original_size;
    size_t output_len = 0;
    text *result;

    if (PG_ARGISNULL(0) || PG_ARGISNULL(1) || PG_ARGISNULL(2) || PG_ARGISNULL(3))
        PG_RETURN_NULL();
    mcdb_require_utf8_database();
    dictionary_ref = PG_GETARG_INT64(1);
    if (dictionary_ref <= 0)
        mcdb_raise_dictionary("dictionary reference must be a positive signed bigint");
    dictionary_sha256 = PG_GETARG_BYTEA_PP(2);
    if (VARSIZE_ANY_EXHDR(dictionary_sha256) != MCDB_SHA256_BYTES)
        mcdb_raise_dictionary("dictionary sha256 must be exactly 32 bytes");
    input = PG_GETARG_BYTEA_PP(0);
    dictionary = PG_GETARG_BYTEA_PP(3);
    ddict = mcdb_pg_cached_ddict(fcinfo, dictionary_ref,
                                 (const unsigned char *)VARDATA_ANY(dictionary_sha256),
                                 (const unsigned char *)VARDATA_ANY(dictionary),
                                 (size_t)VARSIZE_ANY_EXHDR(dictionary), err, &status);
    if (!ddict || status != MCDB_OK)
        mcdb_raise(status, err);
    status = mcdb_validate_v2_header((const unsigned char *)VARDATA_ANY(input),
                                     (size_t)VARSIZE_ANY_EXHDR(input), &original_size, NULL);
    if (status != MCDB_OK)
        mcdb_raise(status, mcdb_status_str(status));
    result = (text *)palloc(VARHDRSZ + (size_t)original_size);
    status = mcdb_decode_v2_into(
        (const unsigned char *)VARDATA_ANY(input), (size_t)VARSIZE_ANY_EXHDR(input),
        (uint64_t)dictionary_ref, (const unsigned char *)VARDATA_ANY(dictionary),
        (size_t)VARSIZE_ANY_EXHDR(dictionary), mcdb_pg_cache(fcinfo)->dctx, ddict,
        (unsigned char *)VARDATA(result), (size_t)original_size, &output_len, err);
    if (status != MCDB_OK)
        mcdb_raise(status, err);
    SET_VARSIZE(result, VARHDRSZ + output_len);
    PG_RETURN_TEXT_P(result);
}
