#include <ruby.h>
#include <ruby/encoding.h>
#include <zstd.h>
#include <zdict.h>
#include <lz4.h>
#include <lz4hc.h>
#include <brotli/encode.h>
#include <brotli/decode.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

#define MAX_DECOMPRESS_SIZE (256ULL * 1024 * 1024)

static VALUE mMultiCompress;
static VALUE eError;
static VALUE eDataError;
static VALUE eMemError;
static VALUE eStreamError;
static VALUE eUnsupportedError;
static VALUE eLevelError;
static VALUE cDeflater;
static VALUE cInflater;
static VALUE cWriter;
static VALUE cReader;
static VALUE cDictionary;
static VALUE mZstd;
static VALUE mLZ4;
static VALUE mBrotli;

typedef enum { ALGO_ZSTD = 0, ALGO_LZ4 = 1, ALGO_BROTLI = 2 } compress_algo_t;

static compress_algo_t sym_to_algo(VALUE sym) {
    ID id = SYM2ID(sym);
    if (id == rb_intern("zstd"))
        return ALGO_ZSTD;
    if (id == rb_intern("lz4"))
        return ALGO_LZ4;
    if (id == rb_intern("brotli"))
        return ALGO_BROTLI;
    rb_raise(rb_eArgError, "Unknown algorithm: %s", rb_id2name(id));
    return ALGO_ZSTD;
}

static int resolve_level(compress_algo_t algo, VALUE level_val) {
    if (NIL_P(level_val)) {
        switch (algo) {
        case ALGO_ZSTD:
            return 3;
        case ALGO_LZ4:
            return 1;
        case ALGO_BROTLI:
            return 6;
        }
    }

    if (SYMBOL_P(level_val)) {
        ID id = SYM2ID(level_val);
        if (id == rb_intern("fastest")) {
            switch (algo) {
            case ALGO_ZSTD:
                return 1;
            case ALGO_LZ4:
                return 1;
            case ALGO_BROTLI:
                return 0;
            }
        } else if (id == rb_intern("default")) {
            switch (algo) {
            case ALGO_ZSTD:
                return 3;
            case ALGO_LZ4:
                return 1;
            case ALGO_BROTLI:
                return 6;
            }
        } else if (id == rb_intern("best")) {
            switch (algo) {
            case ALGO_ZSTD:
                return 19;
            case ALGO_LZ4:
                return 16;
            case ALGO_BROTLI:
                return 11;
            }
        }
        rb_raise(eLevelError, "Unknown named level: %s", rb_id2name(id));
    }

    int level = NUM2INT(level_val);

    switch (algo) {
    case ALGO_ZSTD:
        if (level < 1 || level > 22)
            rb_raise(eLevelError, "zstd level must be 1..22, got %d", level);
        break;
    case ALGO_LZ4:
        if (level < 1 || level > 16)
            rb_raise(eLevelError, "lz4 level must be 1..16, got %d", level);
        break;
    case ALGO_BROTLI:
        if (level < 0 || level > 11)
            rb_raise(eLevelError, "brotli level must be 0..11, got %d", level);
        break;
    }

    return level;
}

static compress_algo_t detect_algo(const uint8_t *data, size_t len) {
    if (len >= 4) {
        if (data[0] == 0x28 && data[1] == 0xB5 && data[2] == 0x2F && data[3] == 0xFD) {
            return ALGO_ZSTD;
        }
    }

    if (len >= 8) {
        uint32_t orig = (uint32_t)data[0] | ((uint32_t)data[1] << 8) | ((uint32_t)data[2] << 16) |
                        ((uint32_t)data[3] << 24);
        uint32_t comp = (uint32_t)data[4] | ((uint32_t)data[5] << 8) | ((uint32_t)data[6] << 16) |
                        ((uint32_t)data[7] << 24);
        if (orig > 0 && orig <= 256 * 1024 * 1024 && comp > 0 && comp <= 256 * 1024 * 1024 &&
            8 + comp <= len) {
            return ALGO_LZ4;
        }
    }

    rb_raise(eDataError, "cannot detect compression format (no magic bytes found). "
                         "Use algo: :zstd, :lz4, or :brotli explicitly.");
    return ALGO_ZSTD;
}

typedef struct {
    compress_algo_t algo;
    uint8_t *data;
    size_t size;
} dictionary_t;

static void dict_free(void *ptr) {
    dictionary_t *dict = (dictionary_t *)ptr;
    if (dict->data)
        xfree(dict->data);
    xfree(dict);
}

static size_t dict_memsize(const void *ptr) {
    const dictionary_t *d = (const dictionary_t *)ptr;
    return sizeof(dictionary_t) + d->size;
}

static const rb_data_type_t dictionary_type = {
    "Compress::Dictionary", {NULL, dict_free, dict_memsize}, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY};

static VALUE dict_alloc(VALUE klass) {
    dictionary_t *d = ALLOC(dictionary_t);
    memset(d, 0, sizeof(dictionary_t));
    return TypedData_Wrap_Struct(klass, &dictionary_type, d);
}

static VALUE compress_compress(int argc, VALUE *argv, VALUE self) {
    VALUE data, opts;
    rb_scan_args(argc, argv, "1:", &data, &opts);
    StringValue(data);

    VALUE algo_sym = Qnil, level_val = Qnil, dict_val = Qnil;
    if (!NIL_P(opts)) {
        algo_sym = rb_hash_aref(opts, ID2SYM(rb_intern("algo")));
        level_val = rb_hash_aref(opts, ID2SYM(rb_intern("level")));
        dict_val = rb_hash_aref(opts, ID2SYM(rb_intern("dictionary")));
    }

    compress_algo_t algo = NIL_P(algo_sym) ? ALGO_ZSTD : sym_to_algo(algo_sym);
    int level = resolve_level(algo, level_val);

    dictionary_t *dict = NULL;
    if (!NIL_P(dict_val)) {
        if (algo == ALGO_LZ4) {
            rb_raise(eUnsupportedError, "LZ4 does not support dictionaries");
        }
        TypedData_Get_Struct(dict_val, dictionary_t, &dictionary_type, dict);
    }

    const char *src = RSTRING_PTR(data);
    size_t slen = RSTRING_LEN(data);

    switch (algo) {
    case ALGO_ZSTD: {
        size_t bound = ZSTD_compressBound(slen);
        VALUE dst = rb_str_buf_new(bound);

        size_t csize;
        if (dict) {
            ZSTD_CCtx *cctx = ZSTD_createCCtx();
            if (!cctx)
                rb_raise(eMemError, "zstd: failed to create context");
            ZSTD_CDict *cdict = ZSTD_createCDict(dict->data, dict->size, level);
            if (!cdict) {
                ZSTD_freeCCtx(cctx);
                rb_raise(eMemError, "zstd: failed to create cdict");
            }
            csize = ZSTD_compress_usingCDict(cctx, RSTRING_PTR(dst), bound, src, slen, cdict);
            ZSTD_freeCDict(cdict);
            ZSTD_freeCCtx(cctx);
        } else {
            csize = ZSTD_compress(RSTRING_PTR(dst), bound, src, slen, level);
        }

        if (ZSTD_isError(csize)) {
            rb_raise(eError, "zstd compress: %s", ZSTD_getErrorName(csize));
        }
        rb_str_set_len(dst, csize);
        return dst;
    }
    case ALGO_LZ4: {
        if (slen > (size_t)INT_MAX)
            rb_raise(eError, "lz4: input too large (max 2GB)");
        int bound = LZ4_compressBound((int)slen);
        VALUE dst = rb_str_buf_new(8 + bound + 4);
        char *out = RSTRING_PTR(dst);

        out[0] = (slen >> 0) & 0xFF;
        out[1] = (slen >> 8) & 0xFF;
        out[2] = (slen >> 16) & 0xFF;
        out[3] = (slen >> 24) & 0xFF;

        int csize;
        if (level > 1) {
            csize = LZ4_compress_HC(src, out + 8, (int)slen, bound, level);
        } else {
            csize = LZ4_compress_default(src, out + 8, (int)slen, bound);
        }
        if (csize <= 0) {
            rb_raise(eError, "lz4 compress failed");
        }

        out[4] = (csize >> 0) & 0xFF;
        out[5] = (csize >> 8) & 0xFF;
        out[6] = (csize >> 16) & 0xFF;
        out[7] = (csize >> 24) & 0xFF;

        size_t total = 8 + csize;
        out[total] = 0;
        out[total + 1] = 0;
        out[total + 2] = 0;
        out[total + 3] = 0;

        rb_str_set_len(dst, total + 4);
        return dst;
    }
    case ALGO_BROTLI: {
        size_t out_len = BrotliEncoderMaxCompressedSize(slen);
        if (out_len == 0)
            out_len = slen + 1024;
        VALUE dst = rb_str_buf_new(out_len);

        if (dict) {
            BrotliEncoderState *enc = BrotliEncoderCreateInstance(NULL, NULL, NULL);
            if (!enc)
                rb_raise(eMemError, "brotli: failed to create encoder");
            BrotliEncoderSetParameter(enc, BROTLI_PARAM_QUALITY, level);
            BrotliEncoderPreparedDictionary *pd =
                BrotliEncoderPrepareDictionary(BROTLI_SHARED_DICTIONARY_RAW, dict->size, dict->data,
                                               BROTLI_MAX_QUALITY, NULL, NULL, NULL);
            BrotliEncoderAttachPreparedDictionary(enc, pd);

            size_t available_in = slen;
            const uint8_t *next_in = (const uint8_t *)src;
            size_t available_out = out_len;
            uint8_t *next_out = (uint8_t *)RSTRING_PTR(dst);
            size_t initial_out = available_out;

            BROTLI_BOOL ok =
                BrotliEncoderCompressStream(enc, BROTLI_OPERATION_FINISH, &available_in, &next_in,
                                            &available_out, &next_out, NULL);

            BrotliEncoderDestroyPreparedDictionary(pd);
            BrotliEncoderDestroyInstance(enc);
            if (!ok)
                rb_raise(eError, "brotli compress with dict failed");

            rb_str_set_len(dst, initial_out - available_out);
        } else {
            BROTLI_BOOL ok =
                BrotliEncoderCompress(level, BROTLI_DEFAULT_WINDOW, BROTLI_DEFAULT_MODE, slen,
                                      (const uint8_t *)src, &out_len, (uint8_t *)RSTRING_PTR(dst));

            if (!ok)
                rb_raise(eError, "brotli compress failed");
            rb_str_set_len(dst, out_len);
        }
        return dst;
    }
    }

    return Qnil;
}

static VALUE compress_decompress(int argc, VALUE *argv, VALUE self) {
    VALUE data, opts;
    rb_scan_args(argc, argv, "1:", &data, &opts);
    StringValue(data);

    VALUE algo_sym = Qnil, dict_val = Qnil;
    if (!NIL_P(opts)) {
        algo_sym = rb_hash_aref(opts, ID2SYM(rb_intern("algo")));
        dict_val = rb_hash_aref(opts, ID2SYM(rb_intern("dictionary")));
    }

    const uint8_t *src = (const uint8_t *)RSTRING_PTR(data);
    size_t slen = RSTRING_LEN(data);

    compress_algo_t algo;
    if (NIL_P(algo_sym)) {
        algo = detect_algo(src, slen);
    } else {
        algo = sym_to_algo(algo_sym);
    }

    dictionary_t *dict = NULL;
    if (!NIL_P(dict_val)) {
        if (algo == ALGO_LZ4) {
            rb_raise(eUnsupportedError, "LZ4 does not support dictionaries");
        }
        TypedData_Get_Struct(dict_val, dictionary_t, &dictionary_type, dict);
    }

    switch (algo) {
    case ALGO_ZSTD: {
        unsigned long long frame_size = ZSTD_getFrameContentSize(src, slen);
        if (frame_size == ZSTD_CONTENTSIZE_ERROR) {
            rb_raise(eDataError, "zstd: not valid compressed data");
        }

        ZSTD_DCtx *dctx = ZSTD_createDCtx();
        if (!dctx)
            rb_raise(eMemError, "zstd: failed to create dctx");

        if (dict) {
            size_t r = ZSTD_DCtx_loadDictionary(dctx, dict->data, dict->size);
            if (ZSTD_isError(r)) {
                ZSTD_freeDCtx(dctx);
                rb_raise(eError, "zstd dict load: %s", ZSTD_getErrorName(r));
            }
        }

        size_t alloc_size;
        if (frame_size != ZSTD_CONTENTSIZE_UNKNOWN && frame_size <= 256ULL * 1024 * 1024) {
            alloc_size = (size_t)frame_size;
        } else {
            alloc_size = (slen > MAX_DECOMPRESS_SIZE / 8) ? MAX_DECOMPRESS_SIZE : slen * 8;
            if (alloc_size < 4096)
                alloc_size = 4096;
        }

        VALUE dst = rb_str_buf_new(alloc_size);
        size_t total_out = 0;

        ZSTD_inBuffer input = {src, slen, 0};
        while (input.pos < input.size) {
            if (total_out >= alloc_size) {
                if (alloc_size >= MAX_DECOMPRESS_SIZE) {
                    ZSTD_freeDCtx(dctx);
                    rb_raise(eDataError, "zstd: decompressed size exceeds limit (%lluMB)",
                             (unsigned long long)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
                }
                alloc_size *= 2;
                if (alloc_size > MAX_DECOMPRESS_SIZE)
                    alloc_size = MAX_DECOMPRESS_SIZE;
                rb_str_resize(dst, alloc_size);
            }

            ZSTD_outBuffer output = {RSTRING_PTR(dst) + total_out, alloc_size - total_out, 0};
            size_t ret = ZSTD_decompressStream(dctx, &output, &input);
            if (ZSTD_isError(ret)) {
                ZSTD_freeDCtx(dctx);
                rb_raise(eDataError, "zstd decompress: %s", ZSTD_getErrorName(ret));
            }
            total_out += output.pos;
            if (ret == 0)
                break;
        }

        ZSTD_freeDCtx(dctx);
        rb_str_set_len(dst, total_out);
        return dst;
    }
    case ALGO_LZ4: {
        if (slen < 4)
            rb_raise(eDataError, "lz4: data too short");

        VALUE result = rb_str_buf_new(0);
        size_t pos = 0;

        while (pos + 4 <= slen) {
            uint32_t orig_size = (uint32_t)src[pos] | ((uint32_t)src[pos + 1] << 8) |
                                 ((uint32_t)src[pos + 2] << 16) | ((uint32_t)src[pos + 3] << 24);
            if (orig_size == 0)
                break;

            if (pos + 8 > slen)
                rb_raise(eDataError, "lz4: truncated block header");

            uint32_t comp_size = (uint32_t)src[pos + 4] | ((uint32_t)src[pos + 5] << 8) |
                                 ((uint32_t)src[pos + 6] << 16) | ((uint32_t)src[pos + 7] << 24);

            if (pos + 8 + comp_size > slen)
                rb_raise(eDataError, "lz4: truncated block data");
            if (orig_size > 256 * 1024 * 1024)
                rb_raise(eDataError, "lz4: block too large (%u)", orig_size);

            VALUE block = rb_str_buf_new(orig_size);
            int dsize = LZ4_decompress_safe((const char *)(src + pos + 8), RSTRING_PTR(block),
                                            (int)comp_size, (int)orig_size);
            if (dsize < 0)
                rb_raise(eDataError, "lz4 decompress failed");

            rb_str_set_len(block, dsize);
            rb_str_cat(result, RSTRING_PTR(block), dsize);
            pos += 8 + comp_size;
        }

        return result;
    }
    case ALGO_BROTLI: {
        size_t alloc_size = (slen > MAX_DECOMPRESS_SIZE / 4) ? MAX_DECOMPRESS_SIZE : slen * 4;
        if (alloc_size < 1024)
            alloc_size = 1024;

        BrotliDecoderState *dec = BrotliDecoderCreateInstance(NULL, NULL, NULL);
        if (!dec)
            rb_raise(eMemError, "brotli: failed to create decoder");

        if (dict) {
            BrotliDecoderAttachDictionary(dec, BROTLI_SHARED_DICTIONARY_RAW, dict->size,
                                          dict->data);
        }

        VALUE dst = rb_str_buf_new(alloc_size);
        size_t total_out = 0;

        size_t available_in = slen;
        const uint8_t *next_in = src;

        BrotliDecoderResult res = BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT;
        while (res == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
            size_t available_out = alloc_size - total_out;
            uint8_t *next_out = (uint8_t *)RSTRING_PTR(dst) + total_out;

            res = BrotliDecoderDecompressStream(dec, &available_in, &next_in, &available_out,
                                                &next_out, NULL);

            total_out = next_out - (uint8_t *)RSTRING_PTR(dst);

            if (res == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
                if (alloc_size >= MAX_DECOMPRESS_SIZE) {
                    BrotliDecoderDestroyInstance(dec);
                    rb_raise(eDataError, "brotli: decompressed size exceeds limit (%lluMB)",
                             (unsigned long long)(MAX_DECOMPRESS_SIZE / (1024 * 1024)));
                }
                alloc_size *= 2;
                if (alloc_size > MAX_DECOMPRESS_SIZE)
                    alloc_size = MAX_DECOMPRESS_SIZE;
                rb_str_resize(dst, alloc_size);
            }
        }

        BrotliDecoderDestroyInstance(dec);

        if (res != BROTLI_DECODER_RESULT_SUCCESS) {
            rb_raise(eDataError, "brotli decompress failed");
        }
        rb_str_set_len(dst, total_out);
        return dst;
    }
    }

    return Qnil;
}

static const uint32_t crc32_table[256] = {
    0x00000000, 0x77073096, 0xEE0E612C, 0x990951BA, 0x076DC419, 0x706AF48F, 0xE963A535, 0x9E6495A3,
    0x0EDB8832, 0x79DCB8A4, 0xE0D5E91E, 0x97D2D988, 0x09B64C2B, 0x7EB17CBD, 0xE7B82D07, 0x90BF1D91,
    0x1DB71064, 0x6AB020F2, 0xF3B97148, 0x84BE41DE, 0x1ADAD47D, 0x6DDDE4EB, 0xF4D4B551, 0x83D385C7,
    0x136C9856, 0x646BA8C0, 0xFD62F97A, 0x8A65C9EC, 0x14015C4F, 0x63066CD9, 0xFA0F3D63, 0x8D080DF5,
    0x3B6E20C8, 0x4C69105E, 0xD56041E4, 0xA2677172, 0x3C03E4D1, 0x4B04D447, 0xD20D85FD, 0xA50AB56B,
    0x35B5A8FA, 0x42B2986C, 0xDBBBC9D6, 0xACBCF940, 0x32D86CE3, 0x45DF5C75, 0xDCD60DCF, 0xABD13D59,
    0x26D930AC, 0x51DE003A, 0xC8D75180, 0xBFD06116, 0x21B4F4B5, 0x56B3C423, 0xCFBA9599, 0xB8BDA50F,
    0x2802B89E, 0x5F058808, 0xC60CD9B2, 0xB10BE924, 0x2F6F7C87, 0x58684C11, 0xC1611DAB, 0xB6662D3D,
    0x76DC4190, 0x01DB7106, 0x98D220BC, 0xEFD5102A, 0x71B18589, 0x06B6B51F, 0x9FBFE4A5, 0xE8B8D433,
    0x7807C9A2, 0x0F00F934, 0x9609A88E, 0xE10E9818, 0x7F6A0DBB, 0x086D3D2D, 0x91646C97, 0xE6635C01,
    0x6B6B51F4, 0x1C6C6162, 0x856530D8, 0xF262004E, 0x6C0695ED, 0x1B01A57B, 0x8208F4C1, 0xF50FC457,
    0x65B0D9C6, 0x12B7E950, 0x8BBEB8EA, 0xFCB9887C, 0x62DD1DDF, 0x15DA2D49, 0x8CD37CF3, 0xFBD44C65,
    0x4DB26158, 0x3AB551CE, 0xA3BC0074, 0xD4BB30E2, 0x4ADFA541, 0x3DD895D7, 0xA4D1C46D, 0xD3D6F4FB,
    0x4369E96A, 0x346ED9FC, 0xAD678846, 0xDA60B8D0, 0x44042D73, 0x33031DE5, 0xAA0A4C5F, 0xDD0D7CC9,
    0x5005713C, 0x270241AA, 0xBE0B1010, 0xC90C2086, 0x5768B525, 0x206F85B3, 0xB966D409, 0xCE61E49F,
    0x5EDEF90E, 0x29D9C998, 0xB0D09822, 0xC7D7A8B4, 0x59B33D17, 0x2EB40D81, 0xB7BD5C3B, 0xC0BA6CAD,
    0xEDB88320, 0x9ABFB3B6, 0x03B6E20C, 0x74B1D29A, 0xEAD54739, 0x9DD277AF, 0x04DB2615, 0x73DC1683,
    0xE3630B12, 0x94643B84, 0x0D6D6A3E, 0x7A6A5AA8, 0xE40ECF0B, 0x9309FF9D, 0x0A00AE27, 0x7D079EB1,
    0xF00F9344, 0x8708A3D2, 0x1E01F268, 0x6906C2FE, 0xF762575D, 0x806567CB, 0x196C3671, 0x6E6B06E7,
    0xFED41B76, 0x89D32BE0, 0x10DA7A5A, 0x67DD4ACC, 0xF9B9DF6F, 0x8EBEEFF9, 0x17B7BE43, 0x60B08ED5,
    0xD6D6A3E8, 0xA1D1937E, 0x38D8C2C4, 0x4FDFF252, 0xD1BB67F1, 0xA6BC5767, 0x3FB506DD, 0x48B2364B,
    0xD80D2BDA, 0xAF0A1B4C, 0x36034AF6, 0x41047A60, 0xDF60EFC3, 0xA867DF55, 0x316E8EEF, 0x4669BE79,
    0xCB61B38C, 0xBC66831A, 0x256FD2A0, 0x5268E236, 0xCC0C7795, 0xBB0B4703, 0x220216B9, 0x5505262F,
    0xC5BA3BBE, 0xB2BD0B28, 0x2BB45A92, 0x5CB36A04, 0xC2D7FFA7, 0xB5D0CF31, 0x2CD99E8B, 0x5BDEAE1D,
    0x9B64C2B0, 0xEC63F226, 0x756AA39C, 0x026D930A, 0x9C0906A9, 0xEB0E363F, 0x72076785, 0x05005713,
    0x95BF4A82, 0xE2B87A14, 0x7BB12BAE, 0x0CB61B38, 0x92D28E9B, 0xE5D5BE0D, 0x7CDCEFB7, 0x0BDBDF21,
    0x86D3D2D4, 0xF1D4E242, 0x68DDB3F8, 0x1FDA836E, 0x81BE16CD, 0xF6B9265B, 0x6FB077E1, 0x18B74777,
    0x88085AE6, 0xFF0F6A70, 0x66063BCA, 0x11010B5C, 0x8F659EFF, 0xF862AE69, 0x616BFFD3, 0x166CCF45,
    0xA00AE278, 0xD70DD2EE, 0x4E048354, 0x3903B3C2, 0xA7672661, 0xD06016F7, 0x4969474D, 0x3E6E77DB,
    0xAED16A4A, 0xD9D65ADC, 0x40DF0B66, 0x37D83BF0, 0xA9BCAE53, 0xDEBB9EC5, 0x47B2CF7F, 0x30B5FFE9,
    0xBDBDF21C, 0xCABAC28A, 0x53B39330, 0x24B4A3A6, 0xBAD03605, 0xCDD70693, 0x54DE5729, 0x23D967BF,
    0xB3667A2E, 0xC4614AB8, 0x5D681B02, 0x2A6F2B94, 0xB40BBE37, 0xC30C8EA1, 0x5A05DF1B, 0x2D02EF8D};

static VALUE compress_crc32(int argc, VALUE *argv, VALUE self) {
    VALUE data, prev;
    rb_scan_args(argc, argv, "11", &data, &prev);
    StringValue(data);

    const uint8_t *src = (const uint8_t *)RSTRING_PTR(data);
    size_t len = RSTRING_LEN(data);
    uint32_t crc = NIL_P(prev) ? 0 : NUM2UINT(prev);

    crc = ~crc;
    for (size_t i = 0; i < len; i++) {
        crc = crc32_table[(crc ^ src[i]) & 0xFF] ^ (crc >> 8);
    }
    crc = ~crc;

    return UINT2NUM(crc);
}

static VALUE compress_adler32(int argc, VALUE *argv, VALUE self) {
    VALUE data, prev;
    rb_scan_args(argc, argv, "11", &data, &prev);
    StringValue(data);

    const uint8_t *src = (const uint8_t *)RSTRING_PTR(data);
    size_t len = RSTRING_LEN(data);
    uint32_t adler = NIL_P(prev) ? 1 : NUM2UINT(prev);

    uint32_t s1 = adler & 0xFFFF;
    uint32_t s2 = (adler >> 16) & 0xFFFF;
    const uint32_t BASE = 65521;

    while (len > 0) {
        size_t chunk = len > 5552 ? 5552 : len;
        len -= chunk;
        for (size_t i = 0; i < chunk; i++) {
            s1 += src[i];
            s2 += s1;
        }
        s1 %= BASE;
        s2 %= BASE;
        src += chunk;
    }

    return UINT2NUM((s2 << 16) | s1);
}

static VALUE compress_algorithms(VALUE self) {
    VALUE ary = rb_ary_new_capa(3);
    rb_ary_push(ary, ID2SYM(rb_intern("zstd")));
    rb_ary_push(ary, ID2SYM(rb_intern("lz4")));
    rb_ary_push(ary, ID2SYM(rb_intern("brotli")));
    return ary;
}

static VALUE compress_available_p(VALUE self, VALUE algo_sym) {
    sym_to_algo(algo_sym);
    return Qtrue;
}

static VALUE compress_version(VALUE self, VALUE algo_sym) {
    compress_algo_t algo = sym_to_algo(algo_sym);
    switch (algo) {
    case ALGO_ZSTD:
        return rb_str_new_cstr(ZSTD_versionString());
    case ALGO_LZ4:
        return rb_sprintf("%d.%d.%d", LZ4_VERSION_MAJOR, LZ4_VERSION_MINOR, LZ4_VERSION_RELEASE);
    case ALGO_BROTLI:
        return rb_sprintf("%d.%d.%d", BrotliEncoderVersion() >> 24,
                          (BrotliEncoderVersion() >> 12) & 0xFFF, BrotliEncoderVersion() & 0xFFF);
    }
    return Qnil;
}

typedef struct {
    compress_algo_t algo;
    int level;
    int closed;
    int finished;

    union {
        ZSTD_CStream *zstd;
        BrotliEncoderState *brotli;
        LZ4_stream_t *lz4;
    } ctx;

    struct {
        char *buf;
        size_t len;
        size_t cap;
    } lz4_buf;
} deflater_t;

static void deflater_free(void *ptr) {
    deflater_t *d = (deflater_t *)ptr;
    if (!d->closed) {
        switch (d->algo) {
        case ALGO_ZSTD:
            if (d->ctx.zstd)
                ZSTD_freeCStream(d->ctx.zstd);
            break;
        case ALGO_BROTLI:
            if (d->ctx.brotli)
                BrotliEncoderDestroyInstance(d->ctx.brotli);
            break;
        case ALGO_LZ4:
            if (d->ctx.lz4)
                LZ4_freeStream(d->ctx.lz4);
            break;
        }
    }
    if (d->lz4_buf.buf)
        xfree(d->lz4_buf.buf);
    xfree(d);
}

static size_t deflater_memsize(const void *ptr) {
    const deflater_t *d = (const deflater_t *)ptr;
    return sizeof(deflater_t) + d->lz4_buf.cap;
}

static const rb_data_type_t deflater_type = {"Compress::Deflater",
                                             {NULL, deflater_free, deflater_memsize},
                                             0,
                                             0,
                                             RUBY_TYPED_FREE_IMMEDIATELY};

static VALUE deflater_alloc(VALUE klass) {
    deflater_t *d = ALLOC(deflater_t);
    memset(d, 0, sizeof(deflater_t));
    return TypedData_Wrap_Struct(klass, &deflater_type, d);
}

static VALUE deflater_initialize(int argc, VALUE *argv, VALUE self) {
    VALUE opts;
    rb_scan_args(argc, argv, "0:", &opts);

    deflater_t *d;
    TypedData_Get_Struct(self, deflater_t, &deflater_type, d);

    VALUE algo_sym = Qnil, level_val = Qnil, dict_val = Qnil;
    if (!NIL_P(opts)) {
        algo_sym = rb_hash_aref(opts, ID2SYM(rb_intern("algo")));
        level_val = rb_hash_aref(opts, ID2SYM(rb_intern("level")));
        dict_val = rb_hash_aref(opts, ID2SYM(rb_intern("dictionary")));
    }

    d->algo = NIL_P(algo_sym) ? ALGO_ZSTD : sym_to_algo(algo_sym);
    d->level = resolve_level(d->algo, level_val);
    d->closed = 0;
    d->finished = 0;

    dictionary_t *dict = NULL;
    if (!NIL_P(dict_val)) {
        if (d->algo == ALGO_LZ4) {
            rb_raise(eUnsupportedError, "LZ4 does not support dictionaries");
        }
        TypedData_Get_Struct(dict_val, dictionary_t, &dictionary_type, dict);
    }

    switch (d->algo) {
    case ALGO_ZSTD: {
        d->ctx.zstd = ZSTD_createCStream();
        if (!d->ctx.zstd)
            rb_raise(eMemError, "zstd: failed to create stream");

        if (dict) {
            ZSTD_CCtx_reset(d->ctx.zstd, ZSTD_reset_session_only);
            ZSTD_CCtx_setParameter(d->ctx.zstd, ZSTD_c_compressionLevel, d->level);
            size_t r = ZSTD_CCtx_loadDictionary(d->ctx.zstd, dict->data, dict->size);
            if (ZSTD_isError(r))
                rb_raise(eError, "zstd dict load: %s", ZSTD_getErrorName(r));
        } else {
            size_t r = ZSTD_initCStream(d->ctx.zstd, d->level);
            if (ZSTD_isError(r))
                rb_raise(eError, "zstd init: %s", ZSTD_getErrorName(r));
        }
        break;
    }
    case ALGO_BROTLI: {
        d->ctx.brotli = BrotliEncoderCreateInstance(NULL, NULL, NULL);
        if (!d->ctx.brotli)
            rb_raise(eMemError, "brotli: failed to create encoder");
        BrotliEncoderSetParameter(d->ctx.brotli, BROTLI_PARAM_QUALITY, d->level);
        if (dict) {
            BrotliEncoderPreparedDictionary *pd =
                BrotliEncoderPrepareDictionary(BROTLI_SHARED_DICTIONARY_RAW, dict->size, dict->data,
                                               BROTLI_MAX_QUALITY, NULL, NULL, NULL);
            BrotliEncoderAttachPreparedDictionary(d->ctx.brotli, pd);
            BrotliEncoderDestroyPreparedDictionary(pd);
        }
        break;
    }
    case ALGO_LZ4: {
        d->ctx.lz4 = LZ4_createStream();
        if (!d->ctx.lz4)
            rb_raise(eMemError, "lz4: failed to create stream");
        LZ4_resetStream(d->ctx.lz4);
        d->lz4_buf.cap = 64 * 1024;
        d->lz4_buf.buf = ALLOC_N(char, d->lz4_buf.cap);
        d->lz4_buf.len = 0;
        break;
    }
    }

    return self;
}

static VALUE lz4_compress_block(deflater_t *d) {
    if (d->lz4_buf.len == 0)
        return rb_str_new("", 0);

    if (d->lz4_buf.len > (size_t)INT_MAX)
        rb_raise(eError, "lz4: block too large (max 2GB)");
    int src_size = (int)d->lz4_buf.len;
    int bound = LZ4_compressBound(src_size);

    VALUE output = rb_str_buf_new(8 + bound);
    char *out = RSTRING_PTR(output);

    out[0] = (src_size >> 0) & 0xFF;
    out[1] = (src_size >> 8) & 0xFF;
    out[2] = (src_size >> 16) & 0xFF;
    out[3] = (src_size >> 24) & 0xFF;

    int csize = LZ4_compress_fast_continue(d->ctx.lz4, d->lz4_buf.buf, out + 8, src_size, bound, 1);

    if (csize <= 0)
        rb_raise(eError, "lz4 stream compress block failed");

    out[4] = (csize >> 0) & 0xFF;
    out[5] = (csize >> 8) & 0xFF;
    out[6] = (csize >> 16) & 0xFF;
    out[7] = (csize >> 24) & 0xFF;

    rb_str_set_len(output, 8 + csize);
    d->lz4_buf.len = 0;
    return output;
}

static VALUE deflater_write(VALUE self, VALUE chunk) {
    deflater_t *d;
    TypedData_Get_Struct(self, deflater_t, &deflater_type, d);
    if (d->closed)
        rb_raise(eStreamError, "stream is closed");
    if (d->finished)
        rb_raise(eStreamError, "stream is already finished");
    StringValue(chunk);

    const char *src = RSTRING_PTR(chunk);
    size_t slen = RSTRING_LEN(chunk);
    if (slen == 0)
        return rb_str_new("", 0);

    switch (d->algo) {
    case ALGO_ZSTD: {
        ZSTD_inBuffer input = {src, slen, 0};
        size_t out_cap = ZSTD_CStreamOutSize();
        VALUE result = rb_str_buf_new(0);

        while (input.pos < input.size) {
            VALUE buf = rb_str_buf_new(out_cap);
            ZSTD_outBuffer output = {RSTRING_PTR(buf), out_cap, 0};
            size_t ret = ZSTD_compressStream(d->ctx.zstd, &output, &input);
            if (ZSTD_isError(ret))
                rb_raise(eError, "zstd compress stream: %s", ZSTD_getErrorName(ret));
            if (output.pos > 0)
                rb_str_cat(result, RSTRING_PTR(buf), output.pos);
        }
        return result;
    }
    case ALGO_BROTLI: {
        size_t available_in = slen;
        const uint8_t *next_in = (const uint8_t *)src;
        VALUE result = rb_str_buf_new(0);

        while (available_in > 0 || BrotliEncoderHasMoreOutput(d->ctx.brotli)) {
            size_t available_out = 0;
            uint8_t *next_out = NULL;
            BROTLI_BOOL ok =
                BrotliEncoderCompressStream(d->ctx.brotli, BROTLI_OPERATION_PROCESS, &available_in,
                                            &next_in, &available_out, &next_out, NULL);
            if (!ok)
                rb_raise(eError, "brotli compress stream failed");

            const uint8_t *out_data;
            size_t out_size = 0;
            out_data = BrotliEncoderTakeOutput(d->ctx.brotli, &out_size);
            if (out_size > 0)
                rb_str_cat(result, (const char *)out_data, out_size);
        }
        return result;
    }
    case ALGO_LZ4: {
        VALUE result = rb_str_buf_new(0);
        while (slen > 0) {
            size_t space = d->lz4_buf.cap - d->lz4_buf.len;
            size_t copy = slen < space ? slen : space;
            memcpy(d->lz4_buf.buf + d->lz4_buf.len, src, copy);
            d->lz4_buf.len += copy;
            src += copy;
            slen -= copy;
            if (d->lz4_buf.len >= d->lz4_buf.cap) {
                VALUE block = lz4_compress_block(d);
                rb_str_cat(result, RSTRING_PTR(block), RSTRING_LEN(block));
            }
        }
        return result;
    }
    }
    return rb_str_new("", 0);
}

static VALUE deflater_flush(VALUE self) {
    deflater_t *d;
    TypedData_Get_Struct(self, deflater_t, &deflater_type, d);
    if (d->closed)
        rb_raise(eStreamError, "stream is closed");
    if (d->finished)
        rb_raise(eStreamError, "stream is already finished");

    switch (d->algo) {
    case ALGO_ZSTD: {
        size_t out_cap = ZSTD_CStreamOutSize();
        VALUE result = rb_str_buf_new(0);
        size_t ret;
        do {
            VALUE buf = rb_str_buf_new(out_cap);
            ZSTD_outBuffer output = {RSTRING_PTR(buf), out_cap, 0};
            ret = ZSTD_flushStream(d->ctx.zstd, &output);
            if (ZSTD_isError(ret))
                rb_raise(eError, "zstd flush: %s", ZSTD_getErrorName(ret));
            if (output.pos > 0)
                rb_str_cat(result, RSTRING_PTR(buf), output.pos);
        } while (ret > 0);
        return result;
    }
    case ALGO_BROTLI: {
        size_t available_in = 0;
        const uint8_t *next_in = NULL;
        VALUE result = rb_str_buf_new(0);
        do {
            size_t available_out = 0;
            uint8_t *next_out = NULL;
            BROTLI_BOOL ok =
                BrotliEncoderCompressStream(d->ctx.brotli, BROTLI_OPERATION_FLUSH, &available_in,
                                            &next_in, &available_out, &next_out, NULL);
            if (!ok)
                rb_raise(eError, "brotli flush failed");
            const uint8_t *out_data;
            size_t out_size = 0;
            out_data = BrotliEncoderTakeOutput(d->ctx.brotli, &out_size);
            if (out_size > 0)
                rb_str_cat(result, (const char *)out_data, out_size);
        } while (BrotliEncoderHasMoreOutput(d->ctx.brotli));
        return result;
    }
    case ALGO_LZ4:
        return lz4_compress_block(d);
    }
    return rb_str_new("", 0);
}

static VALUE deflater_finish(VALUE self) {
    deflater_t *d;
    TypedData_Get_Struct(self, deflater_t, &deflater_type, d);
    if (d->closed)
        rb_raise(eStreamError, "stream is closed");
    if (d->finished)
        return rb_str_new("", 0);
    d->finished = 1;

    switch (d->algo) {
    case ALGO_ZSTD: {
        size_t out_cap = ZSTD_CStreamOutSize();
        VALUE result = rb_str_buf_new(0);
        size_t ret;
        do {
            VALUE buf = rb_str_buf_new(out_cap);
            ZSTD_outBuffer output = {RSTRING_PTR(buf), out_cap, 0};
            ret = ZSTD_endStream(d->ctx.zstd, &output);
            if (ZSTD_isError(ret))
                rb_raise(eError, "zstd end stream: %s", ZSTD_getErrorName(ret));
            if (output.pos > 0)
                rb_str_cat(result, RSTRING_PTR(buf), output.pos);
        } while (ret > 0);
        return result;
    }
    case ALGO_BROTLI: {
        size_t available_in = 0;
        const uint8_t *next_in = NULL;
        VALUE result = rb_str_buf_new(0);
        do {
            size_t available_out = 0;
            uint8_t *next_out = NULL;
            BROTLI_BOOL ok =
                BrotliEncoderCompressStream(d->ctx.brotli, BROTLI_OPERATION_FINISH, &available_in,
                                            &next_in, &available_out, &next_out, NULL);
            if (!ok)
                rb_raise(eError, "brotli finish failed");
            const uint8_t *out_data;
            size_t out_size = 0;
            out_data = BrotliEncoderTakeOutput(d->ctx.brotli, &out_size);
            if (out_size > 0)
                rb_str_cat(result, (const char *)out_data, out_size);
        } while (BrotliEncoderHasMoreOutput(d->ctx.brotli) ||
                 !BrotliEncoderIsFinished(d->ctx.brotli));
        return result;
    }
    case ALGO_LZ4: {
        VALUE result = rb_str_buf_new(0);
        if (d->lz4_buf.len > 0) {
            VALUE block = lz4_compress_block(d);
            rb_str_cat(result, RSTRING_PTR(block), RSTRING_LEN(block));
        }

        char eos[4] = {0, 0, 0, 0};
        rb_str_cat(result, eos, 4);
        return result;
    }
    }
    return rb_str_new("", 0);
}

static VALUE deflater_reset(VALUE self) {
    deflater_t *d;
    TypedData_Get_Struct(self, deflater_t, &deflater_type, d);

    switch (d->algo) {
    case ALGO_ZSTD:
        if (d->ctx.zstd) {
            ZSTD_CCtx_reset(d->ctx.zstd, ZSTD_reset_session_only);
            ZSTD_CCtx_setParameter(d->ctx.zstd, ZSTD_c_compressionLevel, d->level);
        }
        break;
    case ALGO_BROTLI:
        if (d->ctx.brotli) {
            BrotliEncoderDestroyInstance(d->ctx.brotli);
            d->ctx.brotli = BrotliEncoderCreateInstance(NULL, NULL, NULL);
            if (!d->ctx.brotli)
                rb_raise(eMemError, "brotli: failed to recreate encoder");
            BrotliEncoderSetParameter(d->ctx.brotli, BROTLI_PARAM_QUALITY, d->level);
        }
        break;
    case ALGO_LZ4:
        if (d->ctx.lz4)
            LZ4_resetStream(d->ctx.lz4);
        d->lz4_buf.len = 0;
        break;
    }
    d->closed = 0;
    d->finished = 0;
    return self;
}

static VALUE deflater_close(VALUE self) {
    deflater_t *d;
    TypedData_Get_Struct(self, deflater_t, &deflater_type, d);
    if (d->closed)
        return Qnil;

    switch (d->algo) {
    case ALGO_ZSTD:
        if (d->ctx.zstd) {
            ZSTD_freeCStream(d->ctx.zstd);
            d->ctx.zstd = NULL;
        }
        break;
    case ALGO_BROTLI:
        if (d->ctx.brotli) {
            BrotliEncoderDestroyInstance(d->ctx.brotli);
            d->ctx.brotli = NULL;
        }
        break;
    case ALGO_LZ4:
        if (d->ctx.lz4) {
            LZ4_freeStream(d->ctx.lz4);
            d->ctx.lz4 = NULL;
        }
        break;
    }
    d->closed = 1;
    return Qnil;
}

static VALUE deflater_closed_p(VALUE self) {
    deflater_t *d;
    TypedData_Get_Struct(self, deflater_t, &deflater_type, d);
    return d->closed ? Qtrue : Qfalse;
}

typedef struct {
    compress_algo_t algo;
    int closed;
    int finished;

    union {
        ZSTD_DStream *zstd;
        BrotliDecoderState *brotli;
    } ctx;

    struct {
        char *buf;
        size_t len;
        size_t cap;
    } lz4_buf;
} inflater_t;

static void inflater_free(void *ptr) {
    inflater_t *inf = (inflater_t *)ptr;
    if (!inf->closed) {
        switch (inf->algo) {
        case ALGO_ZSTD:
            if (inf->ctx.zstd)
                ZSTD_freeDStream(inf->ctx.zstd);
            break;
        case ALGO_BROTLI:
            if (inf->ctx.brotli)
                BrotliDecoderDestroyInstance(inf->ctx.brotli);
            break;
        case ALGO_LZ4:
            break;
        }
    }
    if (inf->lz4_buf.buf)
        xfree(inf->lz4_buf.buf);
    xfree(inf);
}

static size_t inflater_memsize(const void *ptr) {
    const inflater_t *inf = (const inflater_t *)ptr;
    return sizeof(inflater_t) + inf->lz4_buf.cap;
}

static const rb_data_type_t inflater_type = {"Compress::Inflater",
                                             {NULL, inflater_free, inflater_memsize},
                                             0,
                                             0,
                                             RUBY_TYPED_FREE_IMMEDIATELY};

static VALUE inflater_alloc(VALUE klass) {
    inflater_t *inf = ALLOC(inflater_t);
    memset(inf, 0, sizeof(inflater_t));
    return TypedData_Wrap_Struct(klass, &inflater_type, inf);
}

static VALUE inflater_initialize(int argc, VALUE *argv, VALUE self) {
    VALUE opts;
    rb_scan_args(argc, argv, "0:", &opts);

    inflater_t *inf;
    TypedData_Get_Struct(self, inflater_t, &inflater_type, inf);

    VALUE algo_sym = Qnil, dict_val = Qnil;
    if (!NIL_P(opts)) {
        algo_sym = rb_hash_aref(opts, ID2SYM(rb_intern("algo")));
        dict_val = rb_hash_aref(opts, ID2SYM(rb_intern("dictionary")));
    }

    inf->algo = NIL_P(algo_sym) ? ALGO_ZSTD : sym_to_algo(algo_sym);
    inf->closed = 0;
    inf->finished = 0;

    dictionary_t *dict = NULL;
    if (!NIL_P(dict_val)) {
        if (inf->algo == ALGO_LZ4) {
            rb_raise(eUnsupportedError, "LZ4 does not support dictionaries");
        }
        TypedData_Get_Struct(dict_val, dictionary_t, &dictionary_type, dict);
    }

    switch (inf->algo) {
    case ALGO_ZSTD:
        inf->ctx.zstd = ZSTD_createDStream();
        if (!inf->ctx.zstd)
            rb_raise(eMemError, "zstd: failed to create dstream");
        if (dict) {
            ZSTD_DCtx_reset(inf->ctx.zstd, ZSTD_reset_session_only);
            size_t r = ZSTD_DCtx_loadDictionary(inf->ctx.zstd, dict->data, dict->size);
            if (ZSTD_isError(r))
                rb_raise(eError, "zstd dict load: %s", ZSTD_getErrorName(r));
        } else {
            ZSTD_initDStream(inf->ctx.zstd);
        }
        break;
    case ALGO_BROTLI:
        inf->ctx.brotli = BrotliDecoderCreateInstance(NULL, NULL, NULL);
        if (!inf->ctx.brotli)
            rb_raise(eMemError, "brotli: failed to create decoder");
        if (dict) {
            BrotliDecoderAttachDictionary(inf->ctx.brotli, BROTLI_SHARED_DICTIONARY_RAW, dict->size,
                                          dict->data);
        }
        break;
    case ALGO_LZ4:
        inf->lz4_buf.cap = 16 * 1024;
        inf->lz4_buf.buf = ALLOC_N(char, inf->lz4_buf.cap);
        inf->lz4_buf.len = 0;
        break;
    }

    return self;
}

static VALUE inflater_write(VALUE self, VALUE chunk) {
    inflater_t *inf;
    TypedData_Get_Struct(self, inflater_t, &inflater_type, inf);
    if (inf->closed)
        rb_raise(eStreamError, "stream is closed");
    StringValue(chunk);

    const char *src = RSTRING_PTR(chunk);
    size_t slen = RSTRING_LEN(chunk);
    if (slen == 0)
        return rb_str_new("", 0);

    switch (inf->algo) {
    case ALGO_ZSTD: {
        ZSTD_inBuffer input = {src, slen, 0};
        size_t out_cap = ZSTD_DStreamOutSize();
        VALUE result = rb_str_buf_new(0);
        while (input.pos < input.size) {
            VALUE buf = rb_str_buf_new(out_cap);
            ZSTD_outBuffer output = {RSTRING_PTR(buf), out_cap, 0};
            size_t ret = ZSTD_decompressStream(inf->ctx.zstd, &output, &input);
            if (ZSTD_isError(ret))
                rb_raise(eDataError, "zstd decompress stream: %s", ZSTD_getErrorName(ret));
            if (output.pos > 0)
                rb_str_cat(result, RSTRING_PTR(buf), output.pos);
            if (ret == 0)
                break;
        }
        return result;
    }
    case ALGO_BROTLI: {
        size_t available_in = slen;
        const uint8_t *next_in = (const uint8_t *)src;
        VALUE result = rb_str_buf_new(0);
        while (available_in > 0 || BrotliDecoderHasMoreOutput(inf->ctx.brotli)) {
            size_t available_out = 0;
            uint8_t *next_out = NULL;
            BrotliDecoderResult res = BrotliDecoderDecompressStream(
                inf->ctx.brotli, &available_in, &next_in, &available_out, &next_out, NULL);
            if (res == BROTLI_DECODER_RESULT_ERROR)
                rb_raise(eDataError, "brotli decompress stream: %s",
                         BrotliDecoderErrorString(BrotliDecoderGetErrorCode(inf->ctx.brotli)));
            const uint8_t *out_data;
            size_t out_size = 0;
            out_data = BrotliDecoderTakeOutput(inf->ctx.brotli, &out_size);
            if (out_size > 0)
                rb_str_cat(result, (const char *)out_data, out_size);
            if (res == BROTLI_DECODER_RESULT_SUCCESS)
                break;
            if (res == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT && available_in == 0)
                break;
        }
        return result;
    }
    case ALGO_LZ4: {
        VALUE result = rb_str_buf_new(0);

        size_t needed = inf->lz4_buf.len + slen;
        if (needed > inf->lz4_buf.cap) {
            inf->lz4_buf.cap = needed * 2;
            REALLOC_N(inf->lz4_buf.buf, char, inf->lz4_buf.cap);
        }
        memcpy(inf->lz4_buf.buf + inf->lz4_buf.len, src, slen);
        inf->lz4_buf.len += slen;

        size_t pos = 0;
        while (pos + 4 <= inf->lz4_buf.len) {
            const uint8_t *p = (const uint8_t *)(inf->lz4_buf.buf + pos);
            uint32_t orig_size = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
                                 ((uint32_t)p[3] << 24);
            if (orig_size == 0) {
                inf->finished = 1;
                pos += 4;
                break;
            }
            if (pos + 8 > inf->lz4_buf.len)
                break;
            uint32_t comp_size = (uint32_t)p[4] | ((uint32_t)p[5] << 8) | ((uint32_t)p[6] << 16) |
                                 ((uint32_t)p[7] << 24);
            if (pos + 8 + comp_size > inf->lz4_buf.len)
                break;
            if (orig_size > 64 * 1024 * 1024)
                rb_raise(eDataError, "lz4 stream: block too large (%u)", orig_size);

            VALUE block = rb_str_buf_new(orig_size);
            int dsize = LZ4_decompress_safe(inf->lz4_buf.buf + pos + 8, RSTRING_PTR(block),
                                            (int)comp_size, (int)orig_size);
            if (dsize < 0)
                rb_raise(eDataError, "lz4 stream decompress block failed");
            rb_str_set_len(block, dsize);
            rb_str_cat(result, RSTRING_PTR(block), dsize);
            pos += 8 + comp_size;
        }

        if (pos > 0) {
            inf->lz4_buf.len -= pos;
            if (inf->lz4_buf.len > 0)
                memmove(inf->lz4_buf.buf, inf->lz4_buf.buf + pos, inf->lz4_buf.len);
        }
        return result;
    }
    }
    return rb_str_new("", 0);
}

static VALUE inflater_finish(VALUE self) {
    inflater_t *inf;
    TypedData_Get_Struct(self, inflater_t, &inflater_type, inf);
    if (inf->closed)
        rb_raise(eStreamError, "stream is closed");
    inf->finished = 1;
    return rb_str_new("", 0);
}

static VALUE inflater_reset(VALUE self) {
    inflater_t *inf;
    TypedData_Get_Struct(self, inflater_t, &inflater_type, inf);

    switch (inf->algo) {
    case ALGO_ZSTD:
        if (inf->ctx.zstd)
            ZSTD_DCtx_reset(inf->ctx.zstd, ZSTD_reset_session_only);
        break;
    case ALGO_BROTLI:
        if (inf->ctx.brotli) {
            BrotliDecoderDestroyInstance(inf->ctx.brotli);
            inf->ctx.brotli = BrotliDecoderCreateInstance(NULL, NULL, NULL);
            if (!inf->ctx.brotli)
                rb_raise(eMemError, "brotli: failed to recreate decoder");
        }
        break;
    case ALGO_LZ4:
        inf->lz4_buf.len = 0;
        break;
    }
    inf->closed = 0;
    inf->finished = 0;
    return self;
}

static VALUE inflater_close(VALUE self) {
    inflater_t *inf;
    TypedData_Get_Struct(self, inflater_t, &inflater_type, inf);
    if (inf->closed)
        return Qnil;

    switch (inf->algo) {
    case ALGO_ZSTD:
        if (inf->ctx.zstd) {
            ZSTD_freeDStream(inf->ctx.zstd);
            inf->ctx.zstd = NULL;
        }
        break;
    case ALGO_BROTLI:
        if (inf->ctx.brotli) {
            BrotliDecoderDestroyInstance(inf->ctx.brotli);
            inf->ctx.brotli = NULL;
        }
        break;
    case ALGO_LZ4:
        break;
    }
    inf->closed = 1;
    return Qnil;
}

static VALUE inflater_closed_p(VALUE self) {
    inflater_t *inf;
    TypedData_Get_Struct(self, inflater_t, &inflater_type, inf);
    return inf->closed ? Qtrue : Qfalse;
}

static VALUE dict_initialize(int argc, VALUE *argv, VALUE self) {
    VALUE raw, opts;
    rb_scan_args(argc, argv, "1:", &raw, &opts);
    StringValue(raw);

    dictionary_t *d;
    TypedData_Get_Struct(self, dictionary_t, &dictionary_type, d);

    VALUE algo_sym = Qnil;
    if (!NIL_P(opts)) {
        algo_sym = rb_hash_aref(opts, ID2SYM(rb_intern("algo")));
    }
    d->algo = NIL_P(algo_sym) ? ALGO_ZSTD : sym_to_algo(algo_sym);

    if (d->algo == ALGO_LZ4)
        rb_raise(eUnsupportedError, "LZ4 does not support dictionaries");

    d->size = RSTRING_LEN(raw);
    d->data = ALLOC_N(uint8_t, d->size);
    memcpy(d->data, RSTRING_PTR(raw), d->size);

    return self;
}

static VALUE dict_train(int argc, VALUE *argv, VALUE self) {
    VALUE samples, opts;
    rb_scan_args(argc, argv, "1:", &samples, &opts);
    Check_Type(samples, T_ARRAY);

    VALUE algo_sym = Qnil, size_val = Qnil;
    if (!NIL_P(opts)) {
        algo_sym = rb_hash_aref(opts, ID2SYM(rb_intern("algo")));
        size_val = rb_hash_aref(opts, ID2SYM(rb_intern("size")));
    }

    compress_algo_t algo = NIL_P(algo_sym) ? ALGO_ZSTD : sym_to_algo(algo_sym);
    size_t dict_capacity = NIL_P(size_val) ? 32768 : NUM2SIZET(size_val);

    if (algo == ALGO_LZ4)
        rb_raise(eUnsupportedError, "LZ4 does not support dictionary training");

    long num_samples = RARRAY_LEN(samples);
    if (num_samples < 1)
        rb_raise(rb_eArgError, "need at least 1 sample for training");

    size_t total_size = 0;
    for (long i = 0; i < num_samples; i++) {
        VALUE s = rb_ary_entry(samples, i);
        StringValue(s);
        total_size += RSTRING_LEN(s);
    }

    char *concat = ALLOC_N(char, total_size);
    size_t *sizes = ALLOC_N(size_t, num_samples);
    size_t offset = 0;

    for (long i = 0; i < num_samples; i++) {
        VALUE s = rb_ary_entry(samples, i);
        size_t slen = RSTRING_LEN(s);
        memcpy(concat + offset, RSTRING_PTR(s), slen);
        sizes[i] = slen;
        offset += slen;
    }

    uint8_t *dict_buf = ALLOC_N(uint8_t, dict_capacity);

    if (algo == ALGO_ZSTD) {
        size_t result =
            ZDICT_trainFromBuffer(dict_buf, dict_capacity, concat, sizes, (unsigned)num_samples);
        xfree(concat);
        xfree(sizes);

        if (ZDICT_isError(result)) {
            xfree(dict_buf);
            rb_raise(eError, "zstd dict training: %s", ZDICT_getErrorName(result));
        }

        VALUE dict_obj = rb_obj_alloc(cDictionary);
        dictionary_t *d;
        TypedData_Get_Struct(dict_obj, dictionary_t, &dictionary_type, d);
        d->algo = ALGO_ZSTD;
        d->data = dict_buf;
        d->size = result;
        return dict_obj;
    } else {
        xfree(sizes);
        size_t actual_size = total_size < dict_capacity ? total_size : dict_capacity;
        memcpy(dict_buf, concat, actual_size);
        xfree(concat);

        VALUE dict_obj = rb_obj_alloc(cDictionary);
        dictionary_t *d;
        TypedData_Get_Struct(dict_obj, dictionary_t, &dictionary_type, d);
        d->algo = ALGO_BROTLI;
        d->data = dict_buf;
        d->size = actual_size;
        return dict_obj;
    }
}

static VALUE dict_load(int argc, VALUE *argv, VALUE self) {
    VALUE path, opts;
    rb_scan_args(argc, argv, "1:", &path, &opts);
    StringValue(path);

    VALUE algo_sym = Qnil;
    if (!NIL_P(opts)) {
        algo_sym = rb_hash_aref(opts, ID2SYM(rb_intern("algo")));
    }
    compress_algo_t algo = NIL_P(algo_sym) ? ALGO_ZSTD : sym_to_algo(algo_sym);

    if (algo == ALGO_LZ4)
        rb_raise(eUnsupportedError, "LZ4 does not support dictionaries");

    const char *cpath = RSTRING_PTR(path);
    FILE *f = fopen(cpath, "rb");
    if (!f)
        rb_sys_fail(cpath);

    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (file_size <= 0) {
        fclose(f);
        rb_raise(eDataError, "dictionary file is empty: %s", cpath);
    }

    uint8_t *buf = ALLOC_N(uint8_t, file_size);
    size_t read_bytes = fread(buf, 1, file_size, f);
    fclose(f);

    if ((long)read_bytes != file_size) {
        xfree(buf);
        rb_raise(eDataError, "failed to read dictionary: %s", cpath);
    }

    VALUE dict_obj = rb_obj_alloc(cDictionary);
    dictionary_t *d;
    TypedData_Get_Struct(dict_obj, dictionary_t, &dictionary_type, d);
    d->algo = algo;
    d->data = buf;
    d->size = (size_t)file_size;
    return dict_obj;
}

static VALUE dict_save(VALUE self, VALUE path) {
    dictionary_t *d;
    TypedData_Get_Struct(self, dictionary_t, &dictionary_type, d);

    const char *cpath = StringValueCStr(path);
    FILE *f = fopen(cpath, "wb");
    if (!f)
        rb_sys_fail(cpath);

    size_t written = fwrite(d->data, 1, d->size, f);
    fclose(f);

    if (written != d->size)
        rb_raise(eError, "failed to write dictionary to %s", cpath);
    return path;
}

static VALUE dict_algo(VALUE self) {
    dictionary_t *d;
    TypedData_Get_Struct(self, dictionary_t, &dictionary_type, d);
    switch (d->algo) {
    case ALGO_ZSTD:
        return ID2SYM(rb_intern("zstd"));
    case ALGO_LZ4:
        return ID2SYM(rb_intern("lz4"));
    case ALGO_BROTLI:
        return ID2SYM(rb_intern("brotli"));
    }
    return Qnil;
}

static VALUE dict_size(VALUE self) {
    dictionary_t *d;
    TypedData_Get_Struct(self, dictionary_t, &dictionary_type, d);
    return SIZET2NUM(d->size);
}

void Init_multi_compress(void) {
    mMultiCompress = rb_define_module("MultiCompress");

    eError = rb_define_class_under(mMultiCompress, "Error", rb_eStandardError);
    eDataError = rb_define_class_under(mMultiCompress, "DataError", eError);
    eMemError = rb_define_class_under(mMultiCompress, "MemError", eError);
    eStreamError = rb_define_class_under(mMultiCompress, "StreamError", eError);
    eUnsupportedError = rb_define_class_under(mMultiCompress, "UnsupportedError", eError);
    eLevelError = rb_define_class_under(mMultiCompress, "LevelError", eError);

    mZstd = rb_define_module_under(mMultiCompress, "Zstd");
    mLZ4 = rb_define_module_under(mMultiCompress, "LZ4");
    mBrotli = rb_define_module_under(mMultiCompress, "Brotli");

    rb_define_const(mZstd, "MIN_LEVEL", INT2FIX(1));
    rb_define_const(mZstd, "MAX_LEVEL", INT2FIX(22));
    rb_define_const(mZstd, "DEFAULT_LEVEL", INT2FIX(3));
    rb_define_const(mLZ4, "MIN_LEVEL", INT2FIX(1));
    rb_define_const(mLZ4, "MAX_LEVEL", INT2FIX(16));
    rb_define_const(mLZ4, "DEFAULT_LEVEL", INT2FIX(1));
    rb_define_const(mBrotli, "MIN_LEVEL", INT2FIX(0));
    rb_define_const(mBrotli, "MAX_LEVEL", INT2FIX(11));
    rb_define_const(mBrotli, "DEFAULT_LEVEL", INT2FIX(6));

    rb_define_module_function(mMultiCompress, "compress", compress_compress, -1);
    rb_define_module_function(mMultiCompress, "decompress", compress_decompress, -1);
    rb_define_module_function(mMultiCompress, "crc32", compress_crc32, -1);
    rb_define_module_function(mMultiCompress, "adler32", compress_adler32, -1);
    rb_define_module_function(mMultiCompress, "algorithms", compress_algorithms, 0);
    rb_define_module_function(mMultiCompress, "available?", compress_available_p, 1);
    rb_define_module_function(mMultiCompress, "version", compress_version, 1);

    cDeflater = rb_define_class_under(mMultiCompress, "Deflater", rb_cObject);
    rb_define_alloc_func(cDeflater, deflater_alloc);
    rb_define_method(cDeflater, "initialize", deflater_initialize, -1);
    rb_define_method(cDeflater, "write", deflater_write, 1);
    rb_define_method(cDeflater, "flush", deflater_flush, 0);
    rb_define_method(cDeflater, "finish", deflater_finish, 0);
    rb_define_method(cDeflater, "reset", deflater_reset, 0);
    rb_define_method(cDeflater, "close", deflater_close, 0);
    rb_define_method(cDeflater, "closed?", deflater_closed_p, 0);

    cInflater = rb_define_class_under(mMultiCompress, "Inflater", rb_cObject);
    rb_define_alloc_func(cInflater, inflater_alloc);
    rb_define_method(cInflater, "initialize", inflater_initialize, -1);
    rb_define_method(cInflater, "write", inflater_write, 1);
    rb_define_method(cInflater, "finish", inflater_finish, 0);
    rb_define_method(cInflater, "reset", inflater_reset, 0);
    rb_define_method(cInflater, "close", inflater_close, 0);
    rb_define_method(cInflater, "closed?", inflater_closed_p, 0);

    cWriter = rb_define_class_under(mMultiCompress, "Writer", rb_cObject);
    cReader = rb_define_class_under(mMultiCompress, "Reader", rb_cObject);

    cDictionary = rb_define_class_under(mMultiCompress, "Dictionary", rb_cObject);
    rb_define_alloc_func(cDictionary, dict_alloc);
    rb_define_method(cDictionary, "initialize", dict_initialize, -1);
    rb_define_singleton_method(cDictionary, "train", dict_train, -1);
    rb_define_singleton_method(cDictionary, "load", dict_load, -1);
    rb_define_method(cDictionary, "save", dict_save, 1);
    rb_define_method(cDictionary, "algo", dict_algo, 0);
    rb_define_method(cDictionary, "size", dict_size, 0);
}
