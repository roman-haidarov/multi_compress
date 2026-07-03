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

mcdb_udf_init_result_t multi_compress_db_version_init(UDF_INIT *initid, UDF_ARGS *args,
                                                      char *message) {
    (void)args;
    if (args->arg_count != 0) {
        strcpy(message, "multi_compress_db_version() takes no arguments");
        return 1;
    }
    initid->maybe_null = 0;
    initid->const_item = 1;
    initid->max_length = 64;
    return 0;
}

char *multi_compress_db_version(UDF_INIT *initid, UDF_ARGS *args, char *result,
                                unsigned long *length, char *is_null, char *error) {
    (void)initid;
    (void)args;
    *is_null = 0;
    *error = 0;
    /* result buffer is 255 bytes per the UDF ABI */
    int n = snprintf(result, 255, "MCDB1 (zstd %s)", ZSTD_versionString());
    *length = (unsigned long)(n > 0 ? n : 0);
    return result;
}

mcdb_udf_init_result_t multi_compress_db_is_valid_init(UDF_INIT *initid, UDF_ARGS *args,
                                                       char *message) {
    if (args->arg_count != 1) {
        strcpy(message, "multi_compress_db_is_valid(blob) takes exactly one argument");
        return 1;
    }
    args->arg_type[0] = STRING_RESULT;
    initid->maybe_null = 1;
    initid->const_item = 0;
    initid->max_length = 1;
    return 0;
}

long long multi_compress_db_is_valid(UDF_INIT *initid, UDF_ARGS *args, char *is_null, char *error) {
    (void)initid;
    *error = 0;
    if (args->args[0] == NULL) {
        *is_null = 1;
        return 0;
    }
    *is_null = 0;

    unsigned char *out = NULL;
    size_t out_len = 0;
    char err[MCDB_ERRLEN];
    mcdb_status st = mcdb_decode((const unsigned char *)args->args[0], (size_t)args->lengths[0],
                                 &out, &out_len, err);
    free(out);
    return st == MCDB_OK ? 1 : 0;
}

mcdb_udf_init_result_t multi_compress_db_decompress_init(UDF_INIT *initid, UDF_ARGS *args,
                                                         char *message) {
    if (args->arg_count != 1) {
        strcpy(message, "multi_compress_db_decompress(blob) takes exactly one argument");
        return 1;
    }
    args->arg_type[0] = STRING_RESULT;
    initid->maybe_null = 1;
    initid->const_item = 0;
    initid->max_length = MCDB_MAX_OUTPUT; /* result can be up to 16 MiB, not the input size */
    initid->ptr = NULL;                   /* holds the malloc'd result between _decompress calls */
    return 0;
}

void multi_compress_db_decompress_deinit(UDF_INIT *initid) {
    if (initid->ptr) {
        free(initid->ptr);
        initid->ptr = NULL;
    }
}

char *multi_compress_db_decompress(UDF_INIT *initid, UDF_ARGS *args, char *result,
                                   unsigned long *length, char *is_null, char *error) {
    (void)result;
    *error = 0;
    if (args->args[0] == NULL) {
        *is_null = 1;
        return NULL;
    }
    if (initid->ptr) {
        free(initid->ptr);
        initid->ptr = NULL;
    }

    unsigned char *out = NULL;
    size_t out_len = 0;
    char err[MCDB_ERRLEN];
    mcdb_status st = mcdb_decode((const unsigned char *)args->args[0], (size_t)args->lengths[0],
                                 &out, &out_len, err);
    if (st != MCDB_OK) {
        *error = 1;
        *is_null = 1;
        free(out);
        return NULL;
    }

    initid->ptr = (char *)out;
    *length = (unsigned long)out_len;
    *is_null = 0;
    return (char *)out;
}
