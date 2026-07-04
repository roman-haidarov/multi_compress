#ifndef MCDB_FORMAT_H
#define MCDB_FORMAT_H

#include <stddef.h>
#include <stdint.h>

#define MCDB_MAGIC0 0x4D /* 'M' */
#define MCDB_MAGIC1 0x43 /* 'C' */
#define MCDB_MAGIC2 0x44 /* 'D' */
#define MCDB_MAGIC3 0x42 /* 'B' */

#define MCDB_VERSION      1
#define MCDB_CODEC_ZSTD   1
#define MCDB_FLAGS_V1     0
#define MCDB_HEADER_SIZE  19
#define MCDB_CRC_OFFSET   15
#define MCDB_MAX_OUTPUT   (16u * 1024u * 1024u) /* 16 MiB decompressed */
#define MCDB_MAX_ENVELOPE 16842771u

#define MCDB_ERRLEN 256
#define MCDB_READER_VERSION "0.5.0"

typedef enum {
    MCDB_OK = 0,
    MCDB_ERR_TRUNCATED,
    MCDB_ERR_ENVELOPE_SIZE,
    MCDB_ERR_MAGIC,
    MCDB_ERR_VERSION,
    MCDB_ERR_CODEC,
    MCDB_ERR_FLAGS,
    MCDB_ERR_SIZE_LIMIT,
    MCDB_ERR_DECOMPRESS,
    MCDB_ERR_TRAILING_DATA,
    MCDB_ERR_FRAME_CONTENT_SIZE,
    MCDB_ERR_SIZE_MISMATCH,
    MCDB_ERR_CRC,
    MCDB_ERR_UTF8,
    MCDB_ERR_ALLOC
} mcdb_status;

mcdb_status mcdb_validate_header(const unsigned char *in, size_t in_len,
                                 uint64_t *out_original_size);

/* The caller must validate the header and size out from it before calling. */
mcdb_status mcdb_decode_into(const unsigned char *in, size_t in_len,
                             unsigned char *out, size_t out_capacity,
                             size_t *out_len, char *errbuf);

mcdb_status mcdb_decode(const unsigned char *in, size_t in_len,
                        unsigned char **out, size_t *out_len,
                        char *errbuf);

const char *mcdb_status_str(mcdb_status s);

#endif
