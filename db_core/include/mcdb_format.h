#ifndef MCDB_FORMAT_H
#define MCDB_FORMAT_H

#include <stddef.h>
#include <stdint.h>

#include <zstd.h>

#define MCDB_MAGIC0 0x4D /* 'M' */
#define MCDB_MAGIC1 0x43 /* 'C' */
#define MCDB_MAGIC2 0x44 /* 'D' */
#define MCDB_MAGIC3 0x42 /* 'B' */

#define MCDB_VERSION_V1 1
#define MCDB_VERSION_V2 2
#define MCDB_CODEC_ZSTD 1
#define MCDB_FLAGS_NONE 0

#define MCDB_V1_HEADER_SIZE 19u
#define MCDB_V2_HEADER_SIZE 27u
#define MCDB_HEADER_SIZE MCDB_V1_HEADER_SIZE /* MCDB1 compatibility alias */
#define MCDB_ORIGINAL_SIZE_OFFSET 7u
#define MCDB_CRC_OFFSET 15u
#define MCDB_DICTIONARY_REF_OFFSET 19u

#define MCDB_MAX_OUTPUT (16u * 1024u * 1024u) /* 16 MiB decompressed */
#define MCDB_MAX_DICTIONARY_BYTES (256u * 1024u)
#define MCDB_MAX_DICTIONARY_REF UINT64_C(0x7FFFFFFFFFFFFFFF)
#define MCDB_MAX_ENVELOPE_V1 16842771u
#define MCDB_MAX_ENVELOPE_V2 16842779u
#define MCDB_MAX_ENVELOPE MCDB_MAX_ENVELOPE_V2

#define MCDB_SHA256_BYTES 32u
#define MCDB_ERRLEN 256
#define MCDB_READER_VERSION "0.6.0"

typedef struct {
    uint8_t version;
    uint64_t original_size;
    uint64_t dictionary_ref;
    size_t header_size;
} mcdb_header;

typedef enum {
    MCDB_OK = 0,
    MCDB_ERR_TRUNCATED,
    MCDB_ERR_ENVELOPE_SIZE,
    MCDB_ERR_MAGIC,
    MCDB_ERR_VERSION,
    MCDB_ERR_CODEC,
    MCDB_ERR_FLAGS,
    MCDB_ERR_SIZE_LIMIT,
    MCDB_ERR_DICTIONARY_REQUIRED,
    MCDB_ERR_DICTIONARY_REF,
    MCDB_ERR_DICTIONARY_SIZE,
    MCDB_ERR_DICTIONARY_ID,
    MCDB_ERR_DECOMPRESS,
    MCDB_ERR_TRAILING_DATA,
    MCDB_ERR_FRAME_CONTENT_SIZE,
    MCDB_ERR_SIZE_MISMATCH,
    MCDB_ERR_CRC,
    MCDB_ERR_UTF8,
    MCDB_ERR_ALLOC
} mcdb_status;

/* Parses MCDB1 or MCDB2. It never decompresses. */
mcdb_status mcdb_parse_header(const unsigned char *in, size_t in_len, mcdb_header *out_header);

/* MCDB1 compatibility API. Rejects MCDB2. */
mcdb_status mcdb_validate_header(const unsigned char *in, size_t in_len,
                                 uint64_t *out_original_size);

/* MCDB2 parser. Rejects MCDB1. */
mcdb_status mcdb_validate_v2_header(const unsigned char *in, size_t in_len,
                                    uint64_t *out_original_size,
                                    uint64_t *out_dictionary_ref);

/* The caller must validate the MCDB1 header before calling. */
mcdb_status mcdb_decode_into(const unsigned char *in, size_t in_len,
                             unsigned char *out, size_t out_capacity,
                             size_t *out_len, char *errbuf);

mcdb_status mcdb_decode(const unsigned char *in, size_t in_len,
                        unsigned char **out, size_t *out_len,
                        char *errbuf);

/* MCDB2 decode. supplied_dictionary_ref must be the registry id passed by SQL. */
mcdb_status mcdb_decode_v2_into(const unsigned char *in, size_t in_len,
                                uint64_t supplied_dictionary_ref,
                                const unsigned char *dictionary,
                                size_t dictionary_len,
                                ZSTD_DCtx *dctx,
                                ZSTD_DDict *ddict,
                                unsigned char *out, size_t out_capacity,
                                size_t *out_len, char *errbuf);

mcdb_status mcdb_decode_v2(const unsigned char *in, size_t in_len,
                           uint64_t supplied_dictionary_ref,
                           const unsigned char *dictionary,
                           size_t dictionary_len,
                           unsigned char **out, size_t *out_len,
                           char *errbuf);

mcdb_status mcdb_validate_dictionary(const unsigned char *dictionary, size_t dictionary_len,
                                     uint32_t *out_zstd_dictionary_id);

uint32_t mcdb_zstd_frame_dictionary_id(const unsigned char *frame, size_t frame_len);
uint64_t mcdb_dictionary_ref(const unsigned char *in, size_t in_len, mcdb_status *out_status);
void mcdb_sha256(const unsigned char *data, size_t len, unsigned char out[MCDB_SHA256_BYTES]);

const char *mcdb_status_str(mcdb_status s);

#endif
