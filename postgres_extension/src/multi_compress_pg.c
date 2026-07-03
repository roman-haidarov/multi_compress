#include "postgres.h"

#include "fmgr.h"
#include "mb/pg_wchar.h"
#include "utils/builtins.h"
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

static void mcdb_require_utf8_database(void) {
    if (GetDatabaseEncoding() != PG_UTF8)
        ereport(
            ERROR,
            (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
             errmsg("multi_compress requires a UTF-8 PostgreSQL database"),
             errdetail("MCDB1 stores UTF-8 text and multi_compress_db_decompress returns text.")));
}

static void mcdb_raise(mcdb_status status, const char *detail) {
    if (status == MCDB_ERR_ALLOC)
        ereport(ERROR, (errcode(ERRCODE_OUT_OF_MEMORY),
                        errmsg("multi_compress: unable to allocate MCDB1 output")));

    ereport(ERROR,
            (errcode(ERRCODE_DATA_CORRUPTED), errmsg("multi_compress: invalid MCDB1 envelope"),
             errdetail("%s", detail && detail[0] ? detail : mcdb_status_str(status))));
}

Datum multi_compress_db_version(PG_FUNCTION_ARGS) {
    char version[64];

    (void)fcinfo;

    snprintf(version, sizeof(version), "MCDB1 (zstd %s)", ZSTD_versionString());
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
    unsigned char *output = NULL;
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

    status = mcdb_decode((const unsigned char *)VARDATA_ANY(input),
                         (size_t)VARSIZE_ANY_EXHDR(input), &output, &output_len, err);
    if (status != MCDB_OK)
        mcdb_raise(status, err);

    SET_VARSIZE(result, VARHDRSZ + output_len);
    if (output_len > 0)
        memcpy(VARDATA(result), output, output_len);
    free(output);

    PG_RETURN_TEXT_P(result);
}
