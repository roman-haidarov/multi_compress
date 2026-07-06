#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef MCDB_MYSQL_UDF_ABI_57
#include "mysql_udf_abi_57.h"
#else
#include <stdbool.h>
#include <mysql.h>

#if defined(MARIADB_BASE_VERSION) || defined(MARIADB_VERSION_ID) || \
    (defined(MYSQL_VERSION_ID) && MYSQL_VERSION_ID < 80000)
typedef my_bool mcdb_udf_init_result_t;
#else
typedef bool mcdb_udf_init_result_t;
#endif
#endif

#ifdef MCDB_MYSQL_UDF_ABI_57
typedef my_bool mcdb_udf_init_result_t;
#endif

#include <zstd.h>

#include "mcdb_format.h"

#define MCDB_MYSQL_DDICT_CACHE_ENTRIES 4

typedef struct {
    uint64_t dictionary_ref;
    unsigned char sha256[MCDB_SHA256_BYTES];
    unsigned char *bytes;
    size_t bytes_len;
    ZSTD_DDict *ddict;
    uint64_t used_at;
} mcdb_mysql_cache_entry;

typedef struct {
    char *output;
    ZSTD_DCtx *dctx;
    uint64_t clock;
    mcdb_mysql_cache_entry entries[MCDB_MYSQL_DDICT_CACHE_ENTRIES];
} mcdb_mysql_dictionary_state;

static void mcdb_mysql_state_free(mcdb_mysql_dictionary_state *state) {
    int i;
    if (!state)
        return;
    free(state->output);
    if (state->dctx)
        ZSTD_freeDCtx(state->dctx);
    for (i = 0; i < MCDB_MYSQL_DDICT_CACHE_ENTRIES; i++) {
        free(state->entries[i].bytes);
        if (state->entries[i].ddict)
            ZSTD_freeDDict(state->entries[i].ddict);
    }
    free(state);
}

static mcdb_mysql_dictionary_state *mcdb_mysql_state_new(void) {
    mcdb_mysql_dictionary_state *state = (mcdb_mysql_dictionary_state *)calloc(1, sizeof(*state));
    if (!state)
        return NULL;
    state->dctx = ZSTD_createDCtx();
    if (!state->dctx) {
        free(state);
        return NULL;
    }
    return state;
}

static int mcdb_mysql_parse_ref(UDF_ARGS *args, uint64_t *out_ref) {
    long long value;
    if (!args->args[1])
        return 0;
    memcpy(&value, args->args[1], sizeof(value));
    if (value <= 0)
        return 0;
    *out_ref = (uint64_t)value;
    return 1;
}

static int mcdb_mysql_cache_victim(mcdb_mysql_dictionary_state *state, int same_key) {
    int i;
    int victim = 0;
    uint64_t oldest = UINT64_MAX;
    if (same_key >= 0)
        return same_key;
    for (i = 0; i < MCDB_MYSQL_DDICT_CACHE_ENTRIES; i++) {
        if (!state->entries[i].ddict)
            return i;
        if (state->entries[i].used_at < oldest) {
            oldest = state->entries[i].used_at;
            victim = i;
        }
    }
    return victim;
}

static ZSTD_DDict *mcdb_mysql_cached_ddict(mcdb_mysql_dictionary_state *state,
                                           uint64_t dictionary_ref,
                                           const unsigned char *dictionary_sha256,
                                           const unsigned char *dictionary, size_t dictionary_len) {
    unsigned char actual_sha256[MCDB_SHA256_BYTES];
    int i;
    int same_key = -1;
    int victim;
    ZSTD_DDict *ddict;

    for (i = 0; i < MCDB_MYSQL_DDICT_CACHE_ENTRIES; i++) {
        mcdb_mysql_cache_entry *entry = &state->entries[i];
        if (!entry->ddict || entry->dictionary_ref != dictionary_ref ||
            memcmp(entry->sha256, dictionary_sha256, MCDB_SHA256_BYTES) != 0)
            continue;
        same_key = i;
        if (entry->bytes_len == dictionary_len &&
            memcmp(entry->bytes, dictionary, dictionary_len) == 0) {
            entry->used_at = ++state->clock;
            return entry->ddict;
        }
        break;
    }

    mcdb_sha256(dictionary, dictionary_len, actual_sha256);
    if (memcmp(actual_sha256, dictionary_sha256, MCDB_SHA256_BYTES) != 0)
        return NULL;
    if (mcdb_validate_dictionary(dictionary, dictionary_len, NULL) != MCDB_OK)
        return NULL;
    ddict = ZSTD_createDDict(dictionary, dictionary_len);
    if (!ddict)
        return NULL;

    victim = mcdb_mysql_cache_victim(state, same_key);
    free(state->entries[victim].bytes);
    if (state->entries[victim].ddict)
        ZSTD_freeDDict(state->entries[victim].ddict);
    state->entries[victim].bytes = (unsigned char *)malloc(dictionary_len);
    if (!state->entries[victim].bytes) {
        ZSTD_freeDDict(ddict);
        state->entries[victim].ddict = NULL;
        state->entries[victim].bytes_len = 0;
        return NULL;
    }
    memcpy(state->entries[victim].bytes, dictionary, dictionary_len);
    state->entries[victim].dictionary_ref = dictionary_ref;
    memcpy(state->entries[victim].sha256, dictionary_sha256, MCDB_SHA256_BYTES);
    state->entries[victim].bytes_len = dictionary_len;
    state->entries[victim].ddict = ddict;
    state->entries[victim].used_at = ++state->clock;
    return ddict;
}

static mcdb_udf_init_result_t mcdb_one_blob_init(UDF_INIT *initid, UDF_ARGS *args, char *message,
                                                 const char *signature, unsigned long max_length) {
    if (args->arg_count != 1) {
        snprintf(message, 255, "%s takes exactly one argument", signature);
        return 1;
    }
    args->arg_type[0] = STRING_RESULT;
    initid->maybe_null = 1;
    initid->const_item = 0;
    initid->max_length = max_length;
    return 0;
}

mcdb_udf_init_result_t multi_compress_db_version_init(UDF_INIT *initid, UDF_ARGS *args,
                                                      char *message) {
    (void)args;
    if (args->arg_count != 0) {
        strcpy(message, "multi_compress_db_version() takes no arguments");
        return 1;
    }
    initid->maybe_null = 0;
    initid->const_item = 1;
    initid->max_length = 96;
    return 0;
}

char *multi_compress_db_version(UDF_INIT *initid, UDF_ARGS *args, char *result,
                                unsigned long *length, char *is_null, char *error) {
    int n;
    (void)initid;
    (void)args;
    *is_null = 0;
    *error = 0;
    n = snprintf(result, 255, "multi_compress reader %s; MCDB1 + MCDB2; zstd %s",
                 MCDB_READER_VERSION, ZSTD_versionString());
    *length = (unsigned long)(n > 0 ? n : 0);
    return result;
}

mcdb_udf_init_result_t multi_compress_db_is_valid_init(UDF_INIT *initid, UDF_ARGS *args,
                                                       char *message) {
    return mcdb_one_blob_init(initid, args, message, "multi_compress_db_is_valid(blob)", 1);
}

long long multi_compress_db_is_valid(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error) {
    unsigned char *out = NULL;
    size_t out_len = 0;
    char err[MCDB_ERRLEN];
    mcdb_status st;
    (void)initid;
    *error = 0;
    if (!args->args[0]) {
        *is_null = 1;
        return 0;
    }
    *is_null = 0;
    st = mcdb_decode((const unsigned char *)args->args[0], (size_t)args->lengths[0], &out, &out_len,
                     err);
    free(out);
    return st == MCDB_OK ? 1 : 0;
}

mcdb_udf_init_result_t multi_compress_db_decompress_init(UDF_INIT *initid, UDF_ARGS *args,
                                                         char *message) {
    mcdb_udf_init_result_t result = mcdb_one_blob_init(
        initid, args, message, "multi_compress_db_decompress(blob)", MCDB_MAX_OUTPUT);
    if (result)
        return result;
    initid->ptr = NULL;
    return 0;
}

void multi_compress_db_decompress_deinit(UDF_INIT *initid) {
    free(initid->ptr);
    initid->ptr = NULL;
}

char *multi_compress_db_decompress(UDF_INIT *initid, UDF_ARGS *args, char *result,
                                   unsigned long *length, char *is_null, char *error) {
    unsigned char *out = NULL;
    size_t out_len = 0;
    char err[MCDB_ERRLEN];
    mcdb_status st;
    (void)result;
    *error = 0;
    if (!args->args[0]) {
        *is_null = 1;
        return NULL;
    }
    free(initid->ptr);
    initid->ptr = NULL;
    st = mcdb_decode((const unsigned char *)args->args[0], (size_t)args->lengths[0], &out, &out_len,
                     err);
    if (st != MCDB_OK) {
        *is_null = 1;
        free(out);
        return NULL;
    }
    initid->ptr = (char *)out;
    *length = (unsigned long)out_len;
    *is_null = 0;
    return (char *)out;
}

mcdb_udf_init_result_t multi_compress_db_original_size_init(UDF_INIT *initid, UDF_ARGS *args,
                                                            char *message) {
    return mcdb_one_blob_init(initid, args, message, "multi_compress_db_original_size(blob)", 20);
}

long long multi_compress_db_original_size(UDF_INIT *initid, UDF_ARGS *args, char *is_null,
                                          char *error) {
    mcdb_header header;
    mcdb_status st;
    (void)initid;
    *error = 0;
    if (!args->args[0]) {
        *is_null = 1;
        return 0;
    }
    st = mcdb_parse_header((const unsigned char *)args->args[0], (size_t)args->lengths[0], &header);
    if (st != MCDB_OK) {
        *is_null = 1;
        return 0;
    }
    *is_null = 0;
    return (long long)header.original_size;
}

mcdb_udf_init_result_t multi_compress_db_dictionary_ref_init(UDF_INIT *initid, UDF_ARGS *args,
                                                             char *message) {
    return mcdb_one_blob_init(initid, args, message, "multi_compress_db_dictionary_ref(blob)", 20);
}

long long multi_compress_db_dictionary_ref(UDF_INIT *initid, UDF_ARGS *args, char *is_null,
                                           char *error) {
    uint64_t ref;
    mcdb_status st;
    (void)initid;
    *error = 0;
    if (!args->args[0]) {
        *is_null = 1;
        return 0;
    }
    ref = mcdb_dictionary_ref((const unsigned char *)args->args[0], (size_t)args->lengths[0], &st);
    if (st != MCDB_OK) {
        *is_null = 1;
        return 0;
    }
    *is_null = 0;
    return (long long)ref;
}

mcdb_udf_init_result_t multi_compress_db_dictionary_zstd_id_init(UDF_INIT *initid, UDF_ARGS *args,
                                                                 char *message) {
    return mcdb_one_blob_init(initid, args, message,
                              "multi_compress_db_dictionary_zstd_id(dictionary)", 20);
}

long long multi_compress_db_dictionary_zstd_id(UDF_INIT *initid, UDF_ARGS *args, char *is_null,
                                               char *error) {
    uint32_t id;
    (void)initid;
    *error = 0;
    if (!args->args[0] || mcdb_validate_dictionary((const unsigned char *)args->args[0],
                                                   (size_t)args->lengths[0], &id) != MCDB_OK) {
        *is_null = 1;
        return 0;
    }
    *is_null = 0;
    return (long long)id;
}

mcdb_udf_init_result_t multi_compress_db_dictionary_sha256_init(UDF_INIT *initid, UDF_ARGS *args,
                                                                char *message) {
    return mcdb_one_blob_init(initid, args, message,
                              "multi_compress_db_dictionary_sha256(dictionary)", MCDB_SHA256_BYTES);
}

char *multi_compress_db_dictionary_sha256(UDF_INIT *initid, UDF_ARGS *args, char *result,
                                          unsigned long *length, char *is_null, char *error) {
    (void)initid;
    *error = 0;
    if (!args->args[0]) {
        *is_null = 1;
        return NULL;
    }
    mcdb_sha256((const unsigned char *)args->args[0], (size_t)args->lengths[0],
                (unsigned char *)result);
    *length = MCDB_SHA256_BYTES;
    *is_null = 0;
    return result;
}

static mcdb_udf_init_result_t mcdb_dict_init(UDF_INIT *initid, UDF_ARGS *args, char *message,
                                             const char *signature, unsigned long max_length) {
    mcdb_mysql_dictionary_state *state;
    if (args->arg_count != 4) {
        snprintf(message, 255, "%s takes exactly four arguments", signature);
        return 1;
    }
    args->arg_type[0] = STRING_RESULT;
    args->arg_type[1] = INT_RESULT;
    args->arg_type[2] = STRING_RESULT;
    args->arg_type[3] = STRING_RESULT;
    initid->maybe_null = 1;
    initid->const_item = 0;
    initid->max_length = max_length;
    state = mcdb_mysql_state_new();
    if (!state) {
        strcpy(message, "multi_compress: could not allocate zstd dictionary cache");
        return 1;
    }
    initid->ptr = (char *)state;
    return 0;
}

mcdb_udf_init_result_t multi_compress_db_is_valid_dict_init(UDF_INIT *initid, UDF_ARGS *args,
                                                            char *message) {
    return mcdb_dict_init(
        initid, args, message,
        "multi_compress_db_is_valid_dict(blob, dictionary_id, dictionary_sha256, dictionary)", 1);
}

mcdb_udf_init_result_t multi_compress_db_decompress_dict_init(UDF_INIT *initid, UDF_ARGS *args,
                                                              char *message) {
    return mcdb_dict_init(
        initid, args, message,
        "multi_compress_db_decompress_dict(blob, dictionary_id, dictionary_sha256, dictionary)",
        MCDB_MAX_OUTPUT);
}

void multi_compress_db_is_valid_dict_deinit(UDF_INIT *initid) {
    mcdb_mysql_state_free((mcdb_mysql_dictionary_state *)initid->ptr);
    initid->ptr = NULL;
}

void multi_compress_db_decompress_dict_deinit(UDF_INIT *initid) {
    mcdb_mysql_state_free((mcdb_mysql_dictionary_state *)initid->ptr);
    initid->ptr = NULL;
}

static mcdb_status mcdb_mysql_decode_v2(UDF_INIT *initid, UDF_ARGS *args, unsigned char **out,
                                        size_t *out_len) {
    mcdb_mysql_dictionary_state *state = (mcdb_mysql_dictionary_state *)initid->ptr;
    uint64_t dictionary_ref;
    ZSTD_DDict *ddict;
    uint64_t original_size;
    unsigned char *buffer;
    char err[MCDB_ERRLEN];
    mcdb_status st;

    if (!args->args[0] || !args->args[1] || !args->args[2] || !args->args[3])
        return MCDB_ERR_DICTIONARY_REQUIRED;
    if (args->lengths[2] != MCDB_SHA256_BYTES || !mcdb_mysql_parse_ref(args, &dictionary_ref))
        return MCDB_ERR_DICTIONARY_REF;
    ddict = mcdb_mysql_cached_ddict(state, dictionary_ref, (const unsigned char *)args->args[2],
                                    (const unsigned char *)args->args[3], (size_t)args->lengths[3]);
    if (!ddict)
        return MCDB_ERR_DICTIONARY_ID;
    st = mcdb_validate_v2_header((const unsigned char *)args->args[0], (size_t)args->lengths[0],
                                 &original_size, NULL);
    if (st != MCDB_OK)
        return st;
    buffer = (unsigned char *)malloc(original_size ? (size_t)original_size : 1);
    if (!buffer)
        return MCDB_ERR_ALLOC;
    st = mcdb_decode_v2_into((const unsigned char *)args->args[0], (size_t)args->lengths[0],
                             dictionary_ref, (const unsigned char *)args->args[3],
                             (size_t)args->lengths[3], state->dctx, ddict, buffer,
                             (size_t)original_size, out_len, err);
    if (st != MCDB_OK) {
        free(buffer);
        return st;
    }
    *out = buffer;
    return MCDB_OK;
}

long long multi_compress_db_is_valid_dict(UDF_INIT *initid, UDF_ARGS *args, char *is_null,
                                          char *error) {
    unsigned char *out = NULL;
    size_t out_len = 0;
    mcdb_status st;
    *error = 0;
    if (!args->args[0] || !args->args[1] || !args->args[2] || !args->args[3]) {
        *is_null = 1;
        return 0;
    }
    st = mcdb_mysql_decode_v2(initid, args, &out, &out_len);
    free(out);
    *is_null = 0;
    return st == MCDB_OK ? 1 : 0;
}

char *multi_compress_db_decompress_dict(UDF_INIT *initid, UDF_ARGS *args, char *result,
                                        unsigned long *length, char *is_null, char *error) {
    mcdb_mysql_dictionary_state *state = (mcdb_mysql_dictionary_state *)initid->ptr;
    unsigned char *out = NULL;
    size_t out_len = 0;
    mcdb_status st;
    (void)result;
    *error = 0;
    if (!args->args[0] || !args->args[1] || !args->args[2] || !args->args[3]) {
        *is_null = 1;
        return NULL;
    }
    free(state->output);
    state->output = NULL;
    st = mcdb_mysql_decode_v2(initid, args, &out, &out_len);
    if (st != MCDB_OK) {
        free(out);
        *is_null = 1;
        return NULL;
    }
    state->output = (char *)out;
    *length = (unsigned long)out_len;
    *is_null = 0;
    return state->output;
}
