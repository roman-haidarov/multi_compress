#include "mcdb_format.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zstd.h>

typedef char mcdb_v1_envelope_bound_check
    [(MCDB_MAX_ENVELOPE_V1 == (unsigned)(MCDB_V1_HEADER_SIZE + ZSTD_COMPRESSBOUND(MCDB_MAX_OUTPUT)))
         ? 1
         : -1];
typedef char mcdb_v2_envelope_bound_check
    [(MCDB_MAX_ENVELOPE_V2 == (unsigned)(MCDB_V2_HEADER_SIZE + ZSTD_COMPRESSBOUND(MCDB_MAX_OUTPUT)))
         ? 1
         : -1];

static uint32_t mcdb_crc32(const unsigned char *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFU;
    size_t i;
    int bit;

    for (i = 0; i < len; i++) {
        crc ^= data[i];
        for (bit = 0; bit < 8; bit++)
            crc = (crc & 1U) ? ((crc >> 1) ^ 0xEDB88320U) : (crc >> 1);
    }
    return crc ^ 0xFFFFFFFFU;
}

static uint64_t read_u64_le(const unsigned char *p) {
    uint64_t v = 0;
    int i;
    for (i = 0; i < 8; i++)
        v |= (uint64_t)p[i] << (8 * i);
    return v;
}

static uint32_t read_u32_le(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static int mcdb_is_valid_utf8(const unsigned char *s, size_t len) {
    size_t i = 0;
    while (i < len) {
        unsigned char c = s[i];
        size_t n;
        unsigned char lo2 = 0x80;
        unsigned char hi2 = 0xBF;
        size_t k;

        if (c < 0x80) {
            if (c == 0)
                return 0;
            i++;
            continue;
        }
        if ((c & 0xE0) == 0xC0) {
            if (c < 0xC2)
                return 0;
            n = 2;
        } else if ((c & 0xF0) == 0xE0) {
            n = 3;
            if (c == 0xE0)
                lo2 = 0xA0;
            if (c == 0xED)
                hi2 = 0x9F;
        } else if ((c & 0xF8) == 0xF0) {
            if (c > 0xF4)
                return 0;
            n = 4;
            if (c == 0xF0)
                lo2 = 0x90;
            if (c == 0xF4)
                hi2 = 0x8F;
        } else {
            return 0;
        }
        if (i + n > len)
            return 0;
        for (k = 1; k < n; k++) {
            unsigned char cc = s[i + k];
            unsigned char lo = k == 1 ? lo2 : 0x80;
            unsigned char hi = k == 1 ? hi2 : 0xBF;
            if (cc < lo || cc > hi)
                return 0;
        }
        i += n;
    }
    return 1;
}

mcdb_status mcdb_parse_header(const unsigned char *in, size_t in_len, mcdb_header *out_header) {
    mcdb_header header;
    size_t max_envelope;

    if (in == NULL || in_len < MCDB_V1_HEADER_SIZE)
        return MCDB_ERR_TRUNCATED;
    if (in[0] != MCDB_MAGIC0 || in[1] != MCDB_MAGIC1 || in[2] != MCDB_MAGIC2 ||
        in[3] != MCDB_MAGIC3)
        return MCDB_ERR_MAGIC;
    if (in[4] != MCDB_VERSION_V1 && in[4] != MCDB_VERSION_V2)
        return MCDB_ERR_VERSION;

    memset(&header, 0, sizeof(header));
    header.version = in[4];
    header.header_size =
        header.version == MCDB_VERSION_V2 ? MCDB_V2_HEADER_SIZE : MCDB_V1_HEADER_SIZE;
    max_envelope = header.version == MCDB_VERSION_V2 ? MCDB_MAX_ENVELOPE_V2 : MCDB_MAX_ENVELOPE_V1;

    if (in_len < header.header_size)
        return MCDB_ERR_TRUNCATED;
    if (in_len > max_envelope)
        return MCDB_ERR_ENVELOPE_SIZE;
    if (in[5] != MCDB_CODEC_ZSTD)
        return MCDB_ERR_CODEC;
    if (in[6] != MCDB_FLAGS_NONE)
        return MCDB_ERR_FLAGS;

    header.original_size = read_u64_le(in + MCDB_ORIGINAL_SIZE_OFFSET);
    if (header.original_size > MCDB_MAX_OUTPUT)
        return MCDB_ERR_SIZE_LIMIT;

    if (header.version == MCDB_VERSION_V2) {
        header.dictionary_ref = read_u64_le(in + MCDB_DICTIONARY_REF_OFFSET);
        if (header.dictionary_ref == 0 || header.dictionary_ref > MCDB_MAX_DICTIONARY_REF)
            return MCDB_ERR_DICTIONARY_REF;
    }

    if (out_header)
        *out_header = header;
    return MCDB_OK;
}

mcdb_status mcdb_validate_header(const unsigned char *in, size_t in_len,
                                 uint64_t *out_original_size) {
    mcdb_header header;
    mcdb_status st = mcdb_parse_header(in, in_len, &header);
    if (st != MCDB_OK)
        return st;
    if (header.version != MCDB_VERSION_V1)
        return MCDB_ERR_VERSION;
    if (out_original_size)
        *out_original_size = header.original_size;
    return MCDB_OK;
}

mcdb_status mcdb_validate_v2_header(const unsigned char *in, size_t in_len,
                                    uint64_t *out_original_size, uint64_t *out_dictionary_ref) {
    mcdb_header header;
    mcdb_status st = mcdb_parse_header(in, in_len, &header);
    if (st != MCDB_OK)
        return st;
    if (header.version != MCDB_VERSION_V2)
        return MCDB_ERR_VERSION;
    if (out_original_size)
        *out_original_size = header.original_size;
    if (out_dictionary_ref)
        *out_dictionary_ref = header.dictionary_ref;
    return MCDB_OK;
}

mcdb_status mcdb_validate_dictionary(const unsigned char *dictionary, size_t dictionary_len,
                                     uint32_t *out_zstd_dictionary_id) {
    uint32_t dict_id;
    if (dictionary == NULL || dictionary_len == 0 || dictionary_len > MCDB_MAX_DICTIONARY_BYTES)
        return MCDB_ERR_DICTIONARY_SIZE;
    dict_id = ZSTD_getDictID_fromDict(dictionary, dictionary_len);
    if (dict_id == 0)
        return MCDB_ERR_DICTIONARY_ID;
    if (out_zstd_dictionary_id)
        *out_zstd_dictionary_id = dict_id;
    return MCDB_OK;
}

uint32_t mcdb_zstd_frame_dictionary_id(const unsigned char *frame, size_t frame_len) {
    if (frame == NULL || frame_len == 0)
        return 0;
    return ZSTD_getDictID_fromFrame(frame, frame_len);
}

uint64_t mcdb_dictionary_ref(const unsigned char *in, size_t in_len, mcdb_status *out_status) {
    mcdb_header header;
    mcdb_status st = mcdb_parse_header(in, in_len, &header);
    if (out_status)
        *out_status = st;
    if (st != MCDB_OK || header.version != MCDB_VERSION_V2) {
        if (out_status && st == MCDB_OK)
            *out_status = MCDB_ERR_VERSION;
        return 0;
    }
    return header.dictionary_ref;
}

static mcdb_status mcdb_validate_frame(const unsigned char *in, size_t in_len,
                                       const mcdb_header *header, const unsigned char **out_frame,
                                       size_t *out_frame_len, char *errbuf) {
    const unsigned char *frame = in + header->header_size;
    size_t frame_len = in_len - header->header_size;
    size_t frame_size;
    unsigned long long content_size;

    if (frame_len == 0) {
        if (errbuf)
            snprintf(errbuf, MCDB_ERRLEN, "MCDB: missing zstd frame");
        return MCDB_ERR_DECOMPRESS;
    }
    frame_size = ZSTD_findFrameCompressedSize(frame, frame_len);
    if (ZSTD_isError(frame_size)) {
        if (errbuf)
            snprintf(errbuf, MCDB_ERRLEN, "MCDB: invalid zstd frame: %s",
                     ZSTD_getErrorName(frame_size));
        return MCDB_ERR_DECOMPRESS;
    }
    if (frame_size != frame_len) {
        if (errbuf)
            snprintf(errbuf, MCDB_ERRLEN,
                     "MCDB: zstd frame has trailing bytes or concatenated frames");
        return MCDB_ERR_TRAILING_DATA;
    }
    content_size = ZSTD_getFrameContentSize(frame, frame_len);
    if (content_size == ZSTD_CONTENTSIZE_ERROR || content_size == ZSTD_CONTENTSIZE_UNKNOWN ||
        content_size != header->original_size) {
        if (errbuf)
            snprintf(errbuf, MCDB_ERRLEN, "MCDB: zstd frame content size does not match header");
        return MCDB_ERR_FRAME_CONTENT_SIZE;
    }
    if (out_frame)
        *out_frame = frame;
    if (out_frame_len)
        *out_frame_len = frame_len;
    return MCDB_OK;
}

static mcdb_status mcdb_finish_decoded(const unsigned char *in, const mcdb_header *header,
                                       unsigned char *out, size_t produced, size_t *out_len,
                                       char *errbuf) {
    uint32_t expected_crc;
    uint32_t actual_crc;
    if (produced != header->original_size) {
        if (errbuf)
            snprintf(errbuf, MCDB_ERRLEN, "MCDB: size mismatch (header %llu, got %zu)",
                     (unsigned long long)header->original_size, produced);
        return MCDB_ERR_SIZE_MISMATCH;
    }
    expected_crc = read_u32_le(in + MCDB_CRC_OFFSET);
    actual_crc = mcdb_crc32(out, produced);
    if (actual_crc != expected_crc) {
        if (errbuf)
            snprintf(errbuf, MCDB_ERRLEN, "MCDB: crc32 mismatch (header %u, computed %u)",
                     expected_crc, actual_crc);
        return MCDB_ERR_CRC;
    }
    if (!mcdb_is_valid_utf8(out, produced)) {
        if (errbuf)
            snprintf(errbuf, MCDB_ERRLEN,
                     "MCDB: payload is not valid UTF-8 text or contains a NUL byte");
        return MCDB_ERR_UTF8;
    }
    if (out_len)
        *out_len = produced;
    return MCDB_OK;
}

mcdb_status mcdb_decode_into(const unsigned char *in, size_t in_len, unsigned char *out,
                             size_t out_capacity, size_t *out_len, char *errbuf) {
    mcdb_header header;
    const unsigned char *frame;
    size_t frame_len;
    size_t produced;
    mcdb_status st;

    if (out_len)
        *out_len = 0;
    if (errbuf)
        errbuf[0] = '\0';
    st = mcdb_parse_header(in, in_len, &header);
    if (st != MCDB_OK)
        return st;
    if (header.version != MCDB_VERSION_V1)
        return MCDB_ERR_VERSION;
    if (out == NULL || out_capacity < header.original_size)
        return MCDB_ERR_SIZE_MISMATCH;
    st = mcdb_validate_frame(in, in_len, &header, &frame, &frame_len, errbuf);
    if (st != MCDB_OK)
        return st;
    produced = ZSTD_decompress(out, (size_t)header.original_size, frame, frame_len);
    if (ZSTD_isError(produced)) {
        if (errbuf)
            snprintf(errbuf, MCDB_ERRLEN, "MCDB: zstd error: %s", ZSTD_getErrorName(produced));
        return MCDB_ERR_DECOMPRESS;
    }
    return mcdb_finish_decoded(in, &header, out, produced, out_len, errbuf);
}

mcdb_status mcdb_decode(const unsigned char *in, size_t in_len, unsigned char **out,
                        size_t *out_len, char *errbuf) {
    mcdb_header header;
    unsigned char *buf;
    mcdb_status st;
    if (out)
        *out = NULL;
    if (out_len)
        *out_len = 0;
    if (errbuf)
        errbuf[0] = '\0';
    st = mcdb_validate_header(in, in_len, &header.original_size);
    if (st != MCDB_OK) {
        if (errbuf)
            snprintf(errbuf, MCDB_ERRLEN, "MCDB: %s", mcdb_status_str(st));
        return st;
    }
    buf = (unsigned char *)malloc(header.original_size ? (size_t)header.original_size : 1);
    if (buf == NULL) {
        if (errbuf)
            snprintf(errbuf, MCDB_ERRLEN, "MCDB: out of memory");
        return MCDB_ERR_ALLOC;
    }
    st = mcdb_decode_into(in, in_len, buf, (size_t)header.original_size, out_len, errbuf);
    if (st != MCDB_OK) {
        free(buf);
        return st;
    }
    if (out)
        *out = buf;
    else
        free(buf);
    return MCDB_OK;
}

mcdb_status mcdb_decode_v2_into(const unsigned char *in, size_t in_len,
                                uint64_t supplied_dictionary_ref, const unsigned char *dictionary,
                                size_t dictionary_len, ZSTD_DCtx *dctx, ZSTD_DDict *ddict,
                                unsigned char *out, size_t out_capacity, size_t *out_len,
                                char *errbuf) {
    mcdb_header header;
    const unsigned char *frame;
    size_t frame_len;
    size_t produced;
    uint32_t dictionary_id;
    uint32_t frame_dictionary_id;
    mcdb_status st;
    int own_dctx = 0;

    if (out_len)
        *out_len = 0;
    if (errbuf)
        errbuf[0] = '\0';
    st = mcdb_parse_header(in, in_len, &header);
    if (st != MCDB_OK)
        return st;
    if (header.version != MCDB_VERSION_V2)
        return MCDB_ERR_VERSION;
    if (supplied_dictionary_ref != header.dictionary_ref)
        return MCDB_ERR_DICTIONARY_REF;
    if (out == NULL || out_capacity < header.original_size)
        return MCDB_ERR_SIZE_MISMATCH;
    st = mcdb_validate_dictionary(dictionary, dictionary_len, &dictionary_id);
    if (st != MCDB_OK)
        return st;
    st = mcdb_validate_frame(in, in_len, &header, &frame, &frame_len, errbuf);
    if (st != MCDB_OK)
        return st;
    frame_dictionary_id = mcdb_zstd_frame_dictionary_id(frame, frame_len);
    if (frame_dictionary_id == 0 || frame_dictionary_id != dictionary_id)
        return MCDB_ERR_DICTIONARY_ID;
    if (ddict == NULL)
        return MCDB_ERR_DICTIONARY_REQUIRED;
    if (dctx == NULL) {
        dctx = ZSTD_createDCtx();
        if (dctx == NULL)
            return MCDB_ERR_ALLOC;
        own_dctx = 1;
    }
    produced = ZSTD_decompress_usingDDict(dctx, out, (size_t)header.original_size, frame, frame_len,
                                          ddict);
    if (own_dctx)
        ZSTD_freeDCtx(dctx);
    if (ZSTD_isError(produced)) {
        if (errbuf)
            snprintf(errbuf, MCDB_ERRLEN, "MCDB: zstd dictionary error: %s",
                     ZSTD_getErrorName(produced));
        return MCDB_ERR_DECOMPRESS;
    }
    return mcdb_finish_decoded(in, &header, out, produced, out_len, errbuf);
}

mcdb_status mcdb_decode_v2(const unsigned char *in, size_t in_len, uint64_t supplied_dictionary_ref,
                           const unsigned char *dictionary, size_t dictionary_len,
                           unsigned char **out, size_t *out_len, char *errbuf) {
    mcdb_header header;
    ZSTD_DDict *ddict;
    mcdb_status st;
    unsigned char *buf;
    if (out)
        *out = NULL;
    if (out_len)
        *out_len = 0;
    st = mcdb_validate_v2_header(in, in_len, &header.original_size, NULL);
    if (st != MCDB_OK)
        return st;
    st = mcdb_validate_dictionary(dictionary, dictionary_len, NULL);
    if (st != MCDB_OK)
        return st;
    ddict = ZSTD_createDDict(dictionary, dictionary_len);
    if (ddict == NULL)
        return MCDB_ERR_ALLOC;
    buf = (unsigned char *)malloc(header.original_size ? (size_t)header.original_size : 1);
    if (buf == NULL) {
        ZSTD_freeDDict(ddict);
        return MCDB_ERR_ALLOC;
    }
    st = mcdb_decode_v2_into(in, in_len, supplied_dictionary_ref, dictionary, dictionary_len, NULL,
                             ddict, buf, (size_t)header.original_size, out_len, errbuf);
    ZSTD_freeDDict(ddict);
    if (st != MCDB_OK) {
        free(buf);
        return st;
    }
    if (out)
        *out = buf;
    else
        free(buf);
    return MCDB_OK;
}

/* Tiny SHA-256 implementation; dictionary registry validation must not depend on pgcrypto/OpenSSL.
 */
typedef struct {
    uint32_t state[8];
    uint64_t bitlen;
    unsigned char data[64];
    size_t datalen;
} mcdb_sha256_ctx;

#define MCDB_ROTR32(x, n) (((x) >> (n)) | ((x) << (32u - (n))))
#define MCDB_CH(x, y, z)  (((x) & (y)) ^ (~(x) & (z)))
#define MCDB_MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define MCDB_EP0(x)       (MCDB_ROTR32((x), 2) ^ MCDB_ROTR32((x), 13) ^ MCDB_ROTR32((x), 22))
#define MCDB_EP1(x)       (MCDB_ROTR32((x), 6) ^ MCDB_ROTR32((x), 11) ^ MCDB_ROTR32((x), 25))
#define MCDB_SIG0(x)      (MCDB_ROTR32((x), 7) ^ MCDB_ROTR32((x), 18) ^ ((x) >> 3))
#define MCDB_SIG1(x)      (MCDB_ROTR32((x), 17) ^ MCDB_ROTR32((x), 19) ^ ((x) >> 10))

static const uint32_t MCDB_SHA256_K[64] = {
    0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U,
    0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU,
    0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU,
    0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
    0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
    0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
    0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U,
    0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
    0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U,
    0xc67178f2U,
};

static void mcdb_sha256_transform(mcdb_sha256_ctx *ctx, const unsigned char data[64]) {
    uint32_t m[64];
    uint32_t a, b, c, d, e, f, g, h;
    uint32_t t1, t2;
    size_t i;
    for (i = 0; i < 16; i++) {
        m[i] = ((uint32_t)data[i * 4] << 24) | ((uint32_t)data[i * 4 + 1] << 16) |
               ((uint32_t)data[i * 4 + 2] << 8) | (uint32_t)data[i * 4 + 3];
    }
    for (i = 16; i < 64; i++)
        m[i] = MCDB_SIG1(m[i - 2]) + m[i - 7] + MCDB_SIG0(m[i - 15]) + m[i - 16];
    a = ctx->state[0];
    b = ctx->state[1];
    c = ctx->state[2];
    d = ctx->state[3];
    e = ctx->state[4];
    f = ctx->state[5];
    g = ctx->state[6];
    h = ctx->state[7];
    for (i = 0; i < 64; i++) {
        t1 = h + MCDB_EP1(e) + MCDB_CH(e, f, g) + MCDB_SHA256_K[i] + m[i];
        t2 = MCDB_EP0(a) + MCDB_MAJ(a, b, c);
        h = g;
        g = f;
        f = e;
        e = d + t1;
        d = c;
        c = b;
        b = a;
        a = t1 + t2;
    }
    ctx->state[0] += a;
    ctx->state[1] += b;
    ctx->state[2] += c;
    ctx->state[3] += d;
    ctx->state[4] += e;
    ctx->state[5] += f;
    ctx->state[6] += g;
    ctx->state[7] += h;
}

static void mcdb_sha256_init(mcdb_sha256_ctx *ctx) {
    static const uint32_t initial[8] = {0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
                                        0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U};
    memcpy(ctx->state, initial, sizeof(initial));
    ctx->bitlen = 0;
    ctx->datalen = 0;
}

static void mcdb_sha256_update(mcdb_sha256_ctx *ctx, const unsigned char *data, size_t len) {
    size_t i;
    for (i = 0; i < len; i++) {
        ctx->data[ctx->datalen++] = data[i];
        if (ctx->datalen == 64) {
            mcdb_sha256_transform(ctx, ctx->data);
            ctx->bitlen += 512;
            ctx->datalen = 0;
        }
    }
}

static void mcdb_sha256_final(mcdb_sha256_ctx *ctx, unsigned char out[MCDB_SHA256_BYTES]) {
    size_t i;
    uint64_t bitlen;
    ctx->bitlen += (uint64_t)ctx->datalen * 8u;
    ctx->data[ctx->datalen++] = 0x80;
    if (ctx->datalen > 56) {
        while (ctx->datalen < 64)
            ctx->data[ctx->datalen++] = 0;
        mcdb_sha256_transform(ctx, ctx->data);
        ctx->datalen = 0;
    }
    while (ctx->datalen < 56)
        ctx->data[ctx->datalen++] = 0;
    bitlen = ctx->bitlen;
    for (i = 0; i < 8; i++)
        ctx->data[63 - i] = (unsigned char)(bitlen >> (8u * i));
    mcdb_sha256_transform(ctx, ctx->data);
    for (i = 0; i < 8; i++) {
        out[i * 4] = (unsigned char)(ctx->state[i] >> 24);
        out[i * 4 + 1] = (unsigned char)(ctx->state[i] >> 16);
        out[i * 4 + 2] = (unsigned char)(ctx->state[i] >> 8);
        out[i * 4 + 3] = (unsigned char)ctx->state[i];
    }
}

void mcdb_sha256(const unsigned char *data, size_t len, unsigned char out[MCDB_SHA256_BYTES]) {
    mcdb_sha256_ctx ctx;
    mcdb_sha256_init(&ctx);
    if (data != NULL && len > 0)
        mcdb_sha256_update(&ctx, data, len);
    mcdb_sha256_final(&ctx, out);
}

const char *mcdb_status_str(mcdb_status s) {
    switch (s) {
    case MCDB_OK:
        return "ok";
    case MCDB_ERR_TRUNCATED:
        return "truncated envelope";
    case MCDB_ERR_ENVELOPE_SIZE:
        return "stored envelope too large";
    case MCDB_ERR_MAGIC:
        return "bad magic";
    case MCDB_ERR_VERSION:
        return "unsupported version";
    case MCDB_ERR_CODEC:
        return "unsupported codec";
    case MCDB_ERR_FLAGS:
        return "reserved flags must be 0";
    case MCDB_ERR_SIZE_LIMIT:
        return "declared size over limit";
    case MCDB_ERR_DICTIONARY_REQUIRED:
        return "dictionary is required";
    case MCDB_ERR_DICTIONARY_REF:
        return "dictionary reference mismatch or invalid reference";
    case MCDB_ERR_DICTIONARY_SIZE:
        return "dictionary is empty or over limit";
    case MCDB_ERR_DICTIONARY_ID:
        return "zstd dictionary identifier mismatch or missing identifier";
    case MCDB_ERR_DECOMPRESS:
        return "corrupt zstd payload";
    case MCDB_ERR_TRAILING_DATA:
        return "trailing bytes or concatenated zstd frames";
    case MCDB_ERR_FRAME_CONTENT_SIZE:
        return "zstd frame content size mismatch";
    case MCDB_ERR_SIZE_MISMATCH:
        return "size mismatch";
    case MCDB_ERR_CRC:
        return "crc32 mismatch";
    case MCDB_ERR_UTF8:
        return "payload is not valid UTF-8 text or contains a NUL byte";
    case MCDB_ERR_ALLOC:
        return "out of memory";
    default:
        return "unknown error";
    }
}
