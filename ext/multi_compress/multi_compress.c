#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/thread.h>
#ifdef HAVE_RUBY_FIBER_SCHEDULER_H
#include <ruby/fiber/scheduler.h>
#endif
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

#define GVL_UNLOCK_THRESHOLD (64 * 1024)
#define FIBER_YIELD_CHUNK    (64 * 1024)

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
static rb_encoding *binary_encoding;

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

static inline VALUE rb_binary_str_new(const char *ptr, long len) {
    VALUE str = rb_str_new(ptr, len);
    rb_enc_associate(str, binary_encoding);
    return str;
}

static inline VALUE rb_binary_str_buf_new(long capa) {
    VALUE str = rb_str_buf_new(capa);
    rb_enc_associate(str, binary_encoding);
    return str;
}

static int has_fiber_scheduler(void) {
#ifdef HAVE_RB_FIBER_SCHEDULER_CURRENT
    VALUE scheduler = rb_fiber_scheduler_current();
    return scheduler != Qnil && scheduler != Qfalse;
#else
    return 0;
#endif
}

static void unblock_noop(void *arg) {
    (void)arg;
}

static inline void run_without_gvl(void *(*func)(void *), void *arg) {
    rb_thread_call_without_gvl(func, arg, unblock_noop, NULL);
}

static inline size_t fiber_maybe_yield(size_t bytes_since_yield, size_t just_processed,
                                       int *did_yield) {
    *did_yield = 0;
    bytes_since_yield += just_processed;
    if (bytes_since_yield >= FIBER_YIELD_CHUNK) {
        if (has_fiber_scheduler()) {
            rb_thread_schedule();
            *did_yield = 1;
        }
        return 0;
    }
    return bytes_since_yield;
}

#define DICT_CDICT_CACHE_SIZE 4

typedef struct {
    int level;
    ZSTD_CDict *cdict;
} cdict_cache_entry_t;

typedef struct {
    compress_algo_t algo;
    uint8_t *data;
    size_t size;

    cdict_cache_entry_t cdict_cache[DICT_CDICT_CACHE_SIZE];
    int cdict_cache_count;

    ZSTD_DDict *ddict;
} dictionary_t;

static void dict_free(void *ptr) {
    dictionary_t *dict = (dictionary_t *)ptr;
    for (int i = 0; i < dict->cdict_cache_count; i++) {
        if (dict->cdict_cache[i].cdict)
            ZSTD_freeCDict(dict->cdict_cache[i].cdict);
    }
    if (dict->ddict)
        ZSTD_freeDDict(dict->ddict);
    if (dict->data)
        xfree(dict->data);
    xfree(dict);
}

static size_t dict_memsize(const void *ptr) {
    const dictionary_t *d = (const dictionary_t *)ptr;
    size_t total = sizeof(dictionary_t) + d->size;

    for (int i = 0; i < d->cdict_cache_count; i++) {
        if (d->cdict_cache[i].cdict)
            total += d->size + 4096;
    }
    if (d->ddict)
        total += d->size + 4096;
    return total;
}

static const rb_data_type_t dictionary_type = {
    "Compress::Dictionary", {NULL, dict_free, dict_memsize}, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY};

static VALUE dict_alloc(VALUE klass) {
    dictionary_t *d = ALLOC(dictionary_t);
    memset(d, 0, sizeof(dictionary_t));
    return TypedData_Wrap_Struct(klass, &dictionary_type, d);
}

static ZSTD_CDict *dict_get_cdict(dictionary_t *dict, int level) {
    for (int i = 0; i < dict->cdict_cache_count; i++) {
        if (dict->cdict_cache[i].level == level)
            return dict->cdict_cache[i].cdict;
    }

    ZSTD_CDict *cdict = ZSTD_createCDict(dict->data, dict->size, level);
    if (!cdict)
        return NULL;

    for (int i = 0; i < dict->cdict_cache_count; i++) {
        if (dict->cdict_cache[i].level == level) {
            ZSTD_freeCDict(cdict);
            return dict->cdict_cache[i].cdict;
        }
    }

    if (dict->cdict_cache_count < DICT_CDICT_CACHE_SIZE) {
        dict->cdict_cache[dict->cdict_cache_count].level = level;
        dict->cdict_cache[dict->cdict_cache_count].cdict = cdict;
        dict->cdict_cache_count++;
    } else {
        ZSTD_CDict *old_cdict = dict->cdict_cache[0].cdict;
        memmove(&dict->cdict_cache[0], &dict->cdict_cache[1],
                sizeof(cdict_cache_entry_t) * (DICT_CDICT_CACHE_SIZE - 1));
        dict->cdict_cache[DICT_CDICT_CACHE_SIZE - 1].level = level;
        dict->cdict_cache[DICT_CDICT_CACHE_SIZE - 1].cdict = cdict;
        if (old_cdict)
            ZSTD_freeCDict(old_cdict);
    }
    return cdict;
}

static ZSTD_DDict *dict_get_ddict(dictionary_t *dict) {
    if (!dict->ddict) {
        dict->ddict = ZSTD_createDDict(dict->data, dict->size);
    }
    return dict->ddict;
}

typedef struct {
    const char *src;
    size_t src_len;
    char *dst;
    size_t dst_cap;
    int level;
    ZSTD_CDict *cdict;
    size_t result;
    int error;
} zstd_compress_args_t;

static void *zstd_compress_nogvl(void *arg) {
    zstd_compress_args_t *a = (zstd_compress_args_t *)arg;
    if (a->cdict) {
        ZSTD_CCtx *cctx = ZSTD_createCCtx();
        if (!cctx) {
            a->error = 1;
            return NULL;
        }
        a->result =
            ZSTD_compress_usingCDict(cctx, a->dst, a->dst_cap, a->src, a->src_len, a->cdict);
        ZSTD_freeCCtx(cctx);
    } else {
        a->result = ZSTD_compress(a->dst, a->dst_cap, a->src, a->src_len, a->level);
    }
    a->error = 0;
    return NULL;
}

typedef struct {
    const void *src;
    size_t src_len;
    void *dst;
    size_t dst_cap;
    ZSTD_DDict *ddict;
    size_t result;
    int error;
} zstd_decompress_args_t;

static void *zstd_decompress_nogvl(void *arg) {
    zstd_decompress_args_t *a = (zstd_decompress_args_t *)arg;
    if (a->ddict) {
        ZSTD_DCtx *dctx = ZSTD_createDCtx();
        if (!dctx) {
            a->error = 1;
            return NULL;
        }
        a->result =
            ZSTD_decompress_usingDDict(dctx, a->dst, a->dst_cap, a->src, a->src_len, a->ddict);
        ZSTD_freeDCtx(dctx);
    } else {
        a->result = ZSTD_decompress(a->dst, a->dst_cap, a->src, a->src_len);
    }
    a->error = 0;
    return NULL;
}

typedef struct {
    const char *src;
    int src_len;
    char *dst;
    int dst_cap;
    int level;
    int result;
} lz4_compress_args_t;

static void *lz4_compress_nogvl(void *arg) {
    lz4_compress_args_t *a = (lz4_compress_args_t *)arg;
    if (a->level > 1) {
        a->result = LZ4_compress_HC(a->src, a->dst, a->src_len, a->dst_cap, a->level);
    } else {
        a->result = LZ4_compress_default(a->src, a->dst, a->src_len, a->dst_cap);
    }
    return NULL;
}

typedef struct {
    int level;
    size_t src_len;
    const uint8_t *src;
    size_t *out_len;
    uint8_t *dst;
    BROTLI_BOOL result;
} brotli_compress_args_t;

static void *brotli_compress_nogvl(void *arg) {
    brotli_compress_args_t *a = (brotli_compress_args_t *)arg;
    a->result = BrotliEncoderCompress(a->level, BROTLI_DEFAULT_WINDOW, BROTLI_DEFAULT_MODE,
                                      a->src_len, a->src, a->out_len, a->dst);
    return NULL;
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

        size_t csize;
        if (slen >= GVL_UNLOCK_THRESHOLD) {
            char *src_buf = xmalloc(slen);
            memcpy(src_buf, src, slen);
            char *dst_buf = xmalloc(bound);

            ZSTD_CDict *cdict = NULL;
            if (dict) {
                cdict = dict_get_cdict(dict, level);
                if (!cdict) {
                    xfree(src_buf);
                    xfree(dst_buf);
                    rb_raise(eMemError, "zstd: failed to create/get cdict");
                }
            }

            zstd_compress_args_t args = {
                .src = src_buf,
                .src_len = slen,
                .dst = dst_buf,
                .dst_cap = bound,
                .level = level,
                .cdict = cdict,
            };
            run_without_gvl(zstd_compress_nogvl, &args);

            if (args.error) {
                xfree(src_buf);
                xfree(dst_buf);
                rb_raise(eMemError, "zstd: failed to create context");
            }
            csize = args.result;

            if (ZSTD_isError(csize)) {
                const char *err = ZSTD_getErrorName(csize);
                xfree(src_buf);
                xfree(dst_buf);
                rb_raise(eError, "zstd compress: %s", err);
            }

            VALUE dst = rb_binary_str_new(dst_buf, (long)csize);
            xfree(src_buf);
            xfree(dst_buf);
            RB_GC_GUARD(data);
            return dst;
        } else {
            VALUE dst = rb_binary_str_buf_new(bound);

            if (dict) {
                ZSTD_CDict *cdict = dict_get_cdict(dict, level);
                if (!cdict)
                    rb_raise(eMemError, "zstd: failed to create/get cdict");
                ZSTD_CCtx *cctx = ZSTD_createCCtx();
                if (!cctx)
                    rb_raise(eMemError, "zstd: failed to create context");
                csize = ZSTD_compress_usingCDict(cctx, RSTRING_PTR(dst), bound, src, slen, cdict);
                ZSTD_freeCCtx(cctx);
            } else {
                csize = ZSTD_compress(RSTRING_PTR(dst), bound, src, slen, level);
            }

            if (ZSTD_isError(csize)) {
                rb_raise(eError, "zstd compress: %s", ZSTD_getErrorName(csize));
            }
            rb_str_set_len(dst, csize);
            RB_GC_GUARD(data);
            return dst;
        }
    }
    case ALGO_LZ4: {
        if (slen > (size_t)INT_MAX)
            rb_raise(eError, "lz4: input too large (max 2GB)");
        int bound = LZ4_compressBound((int)slen);

        int csize;
        if (slen >= GVL_UNLOCK_THRESHOLD) {
            char *src_buf = xmalloc(slen);
            memcpy(src_buf, src, slen);
            char *dst_buf = xmalloc((size_t)bound);

            lz4_compress_args_t args = {
                .src = src_buf,
                .src_len = (int)slen,
                .dst = dst_buf,
                .dst_cap = bound,
                .level = level,
            };
            run_without_gvl(lz4_compress_nogvl, &args);
            csize = args.result;

            if (csize <= 0) {
                xfree(src_buf);
                xfree(dst_buf);
                rb_raise(eError, "lz4 compress failed");
            }

            size_t total = 8 + (size_t)csize + 4;
            VALUE dst = rb_binary_str_buf_new(total);
            char *out = RSTRING_PTR(dst);

            out[0] = (slen >> 0) & 0xFF;
            out[1] = (slen >> 8) & 0xFF;
            out[2] = (slen >> 16) & 0xFF;
            out[3] = (slen >> 24) & 0xFF;
            out[4] = (csize >> 0) & 0xFF;
            out[5] = (csize >> 8) & 0xFF;
            out[6] = (csize >> 16) & 0xFF;
            out[7] = (csize >> 24) & 0xFF;
            memcpy(out + 8, dst_buf, (size_t)csize);
            out[8 + csize] = 0;
            out[8 + csize + 1] = 0;
            out[8 + csize + 2] = 0;
            out[8 + csize + 3] = 0;

            rb_str_set_len(dst, total);
            xfree(src_buf);
            xfree(dst_buf);
            RB_GC_GUARD(data);
            return dst;
        } else {
            VALUE dst = rb_binary_str_buf_new(8 + bound + 4);
            char *out = RSTRING_PTR(dst);

            out[0] = (slen >> 0) & 0xFF;
            out[1] = (slen >> 8) & 0xFF;
            out[2] = (slen >> 16) & 0xFF;
            out[3] = (slen >> 24) & 0xFF;

            if (level > 1) {
                csize = LZ4_compress_HC(src, out + 8, (int)slen, bound, level);
            } else {
                csize = LZ4_compress_default(src, out + 8, (int)slen, bound);
            }
            if (csize <= 0)
                rb_raise(eError, "lz4 compress failed");

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
            RB_GC_GUARD(data);
            return dst;
        }
    }
    case ALGO_BROTLI: {
        size_t out_len = BrotliEncoderMaxCompressedSize(slen);
        if (out_len == 0)
            out_len = slen + (slen >> 2) + 1024;

        if (dict) {
            VALUE dst = rb_binary_str_buf_new(out_len);
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
            RB_GC_GUARD(data);
            return dst;
        } else if (slen >= GVL_UNLOCK_THRESHOLD) {
            uint8_t *src_buf = xmalloc(slen);
            memcpy(src_buf, src, slen);
            uint8_t *dst_buf = xmalloc(out_len);
            size_t actual_out_len = out_len;

            brotli_compress_args_t args = {
                .level = level,
                .src_len = slen,
                .src = src_buf,
                .out_len = &actual_out_len,
                .dst = dst_buf,
            };
            run_without_gvl(brotli_compress_nogvl, &args);

            if (!args.result) {
                xfree(src_buf);
                xfree(dst_buf);
                rb_raise(eError, "brotli compress failed");
            }

            VALUE dst = rb_binary_str_new((const char *)dst_buf, (long)actual_out_len);
            xfree(src_buf);
            xfree(dst_buf);
            RB_GC_GUARD(data);
            return dst;
        } else {
            VALUE dst = rb_binary_str_buf_new(out_len);
            BROTLI_BOOL ok =
                BrotliEncoderCompress(level, BROTLI_DEFAULT_WINDOW, BROTLI_DEFAULT_MODE, slen,
                                      (const uint8_t *)src, &out_len, (uint8_t *)RSTRING_PTR(dst));
            if (!ok)
                rb_raise(eError, "brotli compress failed");
            rb_str_set_len(dst, out_len);
            RB_GC_GUARD(data);
            return dst;
        }
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

        if (frame_size != ZSTD_CONTENTSIZE_UNKNOWN && frame_size <= MAX_DECOMPRESS_SIZE) {
            size_t dsize;

            if (frame_size >= GVL_UNLOCK_THRESHOLD) {
                char *src_buf = xmalloc(slen);
                memcpy(src_buf, src, slen);
                char *dst_buf = xmalloc((size_t)frame_size);

                ZSTD_DDict *ddict = NULL;
                if (dict) {
                    ddict = dict_get_ddict(dict);
                    if (!ddict) {
                        xfree(src_buf);
                        xfree(dst_buf);
                        rb_raise(eMemError, "zstd: failed to create ddict");
                    }
                }

                zstd_decompress_args_t args = {
                    .src = src_buf,
                    .src_len = slen,
                    .dst = dst_buf,
                    .dst_cap = (size_t)frame_size,
                    .ddict = ddict,
                };
                run_without_gvl(zstd_decompress_nogvl, &args);

                if (args.error) {
                    xfree(src_buf);
                    xfree(dst_buf);
                    rb_raise(eMemError, "zstd: failed to create dctx");
                }
                dsize = args.result;

                if (ZSTD_isError(dsize)) {
                    const char *err = ZSTD_getErrorName(dsize);
                    xfree(src_buf);
                    xfree(dst_buf);
                    rb_raise(eDataError, "zstd decompress: %s", err);
                }

                VALUE dst = rb_binary_str_new(dst_buf, (long)dsize);
                xfree(src_buf);
                xfree(dst_buf);
                RB_GC_GUARD(data);
                return dst;
            } else {
                VALUE dst = rb_binary_str_buf_new((size_t)frame_size);

                if (dict) {
                    ZSTD_DDict *ddict = dict_get_ddict(dict);
                    if (!ddict)
                        rb_raise(eMemError, "zstd: failed to create ddict");
                    ZSTD_DCtx *dctx = ZSTD_createDCtx();
                    if (!dctx)
                        rb_raise(eMemError, "zstd: failed to create dctx");
                    dsize = ZSTD_decompress_usingDDict(dctx, RSTRING_PTR(dst), (size_t)frame_size,
                                                       src, slen, ddict);
                    ZSTD_freeDCtx(dctx);
                } else {
                    dsize = ZSTD_decompress(RSTRING_PTR(dst), (size_t)frame_size, src, slen);
                }

                if (ZSTD_isError(dsize))
                    rb_raise(eDataError, "zstd decompress: %s", ZSTD_getErrorName(dsize));
                rb_str_set_len(dst, dsize);
                RB_GC_GUARD(data);
                return dst;
            }
        }

        ZSTD_DCtx *dctx = ZSTD_createDCtx();
        if (!dctx)
            rb_raise(eMemError, "zstd: failed to create dctx");

        if (dict) {
            ZSTD_DDict *ddict = dict_get_ddict(dict);
            if (ddict) {
                size_t r = ZSTD_DCtx_refDDict(dctx, ddict);
                if (ZSTD_isError(r)) {
                    ZSTD_freeDCtx(dctx);
                    rb_raise(eError, "zstd dict ref: %s", ZSTD_getErrorName(r));
                }
            }
        }

        size_t alloc_size = (slen > MAX_DECOMPRESS_SIZE / 8) ? MAX_DECOMPRESS_SIZE : slen * 8;
        if (alloc_size < 4096)
            alloc_size = 4096;

        VALUE dst = rb_binary_str_buf_new(alloc_size);
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
        RB_GC_GUARD(data);
        return dst;
    }
    case ALGO_LZ4: {
        if (slen < 4)
            rb_raise(eDataError, "lz4: data too short");

        size_t total_orig = 0;
        size_t scan_pos = 0;
        while (scan_pos + 4 <= slen) {
            uint32_t orig_size = (uint32_t)src[scan_pos] | ((uint32_t)src[scan_pos + 1] << 8) |
                                 ((uint32_t)src[scan_pos + 2] << 16) |
                                 ((uint32_t)src[scan_pos + 3] << 24);
            if (orig_size == 0)
                break;
            if (scan_pos + 8 > slen)
                rb_raise(eDataError, "lz4: truncated block header");
            uint32_t comp_size = (uint32_t)src[scan_pos + 4] | ((uint32_t)src[scan_pos + 5] << 8) |
                                 ((uint32_t)src[scan_pos + 6] << 16) |
                                 ((uint32_t)src[scan_pos + 7] << 24);
            if (scan_pos + 8 + comp_size > slen)
                rb_raise(eDataError, "lz4: truncated block data");
            if (orig_size > 256 * 1024 * 1024)
                rb_raise(eDataError, "lz4: block too large (%u)", orig_size);
            total_orig += orig_size;
            if (total_orig > MAX_DECOMPRESS_SIZE)
                rb_raise(eDataError, "lz4: total decompressed size exceeds limit");
            scan_pos += 8 + comp_size;
        }

        VALUE result = rb_binary_str_buf_new(total_orig);
        char *out_ptr = RSTRING_PTR(result);
        size_t out_offset = 0;
        size_t pos = 0;

        while (pos + 4 <= slen) {
            uint32_t orig_size = (uint32_t)src[pos] | ((uint32_t)src[pos + 1] << 8) |
                                 ((uint32_t)src[pos + 2] << 16) | ((uint32_t)src[pos + 3] << 24);
            if (orig_size == 0)
                break;
            uint32_t comp_size = (uint32_t)src[pos + 4] | ((uint32_t)src[pos + 5] << 8) |
                                 ((uint32_t)src[pos + 6] << 16) | ((uint32_t)src[pos + 7] << 24);

            int dsize = LZ4_decompress_safe((const char *)(src + pos + 8), out_ptr + out_offset,
                                            (int)comp_size, (int)orig_size);
            if (dsize < 0)
                rb_raise(eDataError, "lz4 decompress failed");

            out_offset += dsize;
            pos += 8 + comp_size;
        }

        rb_str_set_len(result, out_offset);
        RB_GC_GUARD(data);
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

        VALUE dst = rb_binary_str_buf_new(alloc_size);
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
        RB_GC_GUARD(data);
        return dst;
    }
    }

    return Qnil;
}

static uint32_t crc32_tables[8][256];
static int crc32_tables_initialized = 0;

static void crc32_init_tables(void) {
    if (crc32_tables_initialized)
        return;

    for (uint32_t i = 0; i < 256; i++) {
        uint32_t crc = i;
        for (int j = 0; j < 8; j++) {
            crc = (crc >> 1) ^ (0xEDB88320 & (-(int32_t)(crc & 1)));
        }
        crc32_tables[0][i] = crc;
    }

    for (uint32_t i = 0; i < 256; i++) {
        uint32_t crc = crc32_tables[0][i];
        for (int t = 1; t < 8; t++) {
            crc = crc32_tables[0][crc & 0xFF] ^ (crc >> 8);
            crc32_tables[t][i] = crc;
        }
    }

    crc32_tables_initialized = 1;
}

static uint32_t crc32_compute(const uint8_t *data, size_t len, uint32_t crc) {
    crc = ~crc;

    while (len >= 8) {
        uint32_t val0 = crc ^ ((uint32_t)data[0] | ((uint32_t)data[1] << 8) |
                               ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24));
        uint32_t val1 = (uint32_t)data[4] | ((uint32_t)data[5] << 8) | ((uint32_t)data[6] << 16) |
                        ((uint32_t)data[7] << 24);

        crc = crc32_tables[7][(val0) & 0xFF] ^ crc32_tables[6][(val0 >> 8) & 0xFF] ^
              crc32_tables[5][(val0 >> 16) & 0xFF] ^ crc32_tables[4][(val0 >> 24) & 0xFF] ^
              crc32_tables[3][(val1) & 0xFF] ^ crc32_tables[2][(val1 >> 8) & 0xFF] ^
              crc32_tables[1][(val1 >> 16) & 0xFF] ^ crc32_tables[0][(val1 >> 24) & 0xFF];

        data += 8;
        len -= 8;
    }

    while (len--) {
        crc = crc32_tables[0][(crc ^ *data++) & 0xFF] ^ (crc >> 8);
    }

    return ~crc;
}

static VALUE compress_crc32(int argc, VALUE *argv, VALUE self) {
    VALUE data, prev;
    rb_scan_args(argc, argv, "11", &data, &prev);
    StringValue(data);

    const uint8_t *src = (const uint8_t *)RSTRING_PTR(data);
    size_t len = RSTRING_LEN(data);
    uint32_t crc = NIL_P(prev) ? 0 : NUM2UINT(prev);

    return UINT2NUM(crc32_compute(src, len, crc));
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

#define LZ4_RING_BUFFER_SIZE  (64 * 1024)
#define LZ4_RING_BUFFER_TOTAL (LZ4_RING_BUFFER_SIZE * 2)

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
        size_t ring_offset;
        size_t pending;
    } lz4_ring;
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
    if (d->lz4_ring.buf)
        xfree(d->lz4_ring.buf);
    xfree(d);
}

static size_t deflater_memsize(const void *ptr) {
    const deflater_t *d = (const deflater_t *)ptr;
    size_t s = sizeof(deflater_t);
    if (d->lz4_ring.buf)
        s += LZ4_RING_BUFFER_TOTAL;
    return s;
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
        d->lz4_ring.buf = ALLOC_N(char, LZ4_RING_BUFFER_TOTAL);
        d->lz4_ring.ring_offset = 0;
        d->lz4_ring.pending = 0;
        break;
    }
    }

    return self;
}

static VALUE lz4_compress_ring_block(deflater_t *d) {
    if (d->lz4_ring.pending == 0)
        return rb_binary_str_new("", 0);

    char *block_start = d->lz4_ring.buf + d->lz4_ring.ring_offset - d->lz4_ring.pending;
    int src_size = (int)d->lz4_ring.pending;
    int bound = LZ4_compressBound(src_size);

    VALUE output = rb_binary_str_buf_new(8 + bound);
    char *out = RSTRING_PTR(output);

    out[0] = (src_size >> 0) & 0xFF;
    out[1] = (src_size >> 8) & 0xFF;
    out[2] = (src_size >> 16) & 0xFF;
    out[3] = (src_size >> 24) & 0xFF;

    int csize = LZ4_compress_fast_continue(d->ctx.lz4, block_start, out + 8, src_size, bound, 1);
    if (csize <= 0)
        rb_raise(eError, "lz4 stream compress block failed");

    out[4] = (csize >> 0) & 0xFF;
    out[5] = (csize >> 8) & 0xFF;
    out[6] = (csize >> 16) & 0xFF;
    out[7] = (csize >> 24) & 0xFF;

    rb_str_set_len(output, 8 + csize);
    d->lz4_ring.pending = 0;

    if (d->lz4_ring.ring_offset >= LZ4_RING_BUFFER_SIZE) {
        d->lz4_ring.ring_offset = 0;
    }

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
        return rb_binary_str_new("", 0);

    switch (d->algo) {
    case ALGO_ZSTD: {
        ZSTD_inBuffer input = {src, slen, 0};
        size_t out_cap = ZSTD_CStreamOutSize();
        size_t result_cap = out_cap > slen ? out_cap : slen;
        VALUE result = rb_binary_str_buf_new(result_cap);
        size_t result_len = 0;
        int use_fiber = has_fiber_scheduler();
        size_t fiber_counter = 0;

        while (input.pos < input.size) {
            if (result_len + out_cap > result_cap) {
                result_cap = result_cap * 2;
                rb_str_resize(result, result_cap);
            }

            ZSTD_outBuffer output = {RSTRING_PTR(result) + result_len, out_cap, 0};
            size_t ret = ZSTD_compressStream(d->ctx.zstd, &output, &input);
            if (ZSTD_isError(ret))
                rb_raise(eError, "zstd compress stream: %s", ZSTD_getErrorName(ret));
            result_len += output.pos;
            if (use_fiber) {
                int did_yield = 0;
                fiber_counter = fiber_maybe_yield(fiber_counter, output.pos, &did_yield);
                (void)did_yield;
            }
        }
        rb_str_set_len(result, result_len);
        RB_GC_GUARD(chunk);
        return result;
    }
    case ALGO_BROTLI: {
        size_t available_in = slen;
        const uint8_t *next_in = (const uint8_t *)src;
        size_t result_cap = slen;
        if (result_cap < 1024)
            result_cap = 1024;
        VALUE result = rb_binary_str_buf_new(result_cap);
        size_t result_len = 0;
        int use_fiber = has_fiber_scheduler();
        size_t fiber_counter = 0;

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
            if (out_size > 0) {
                if (result_len + out_size > result_cap) {
                    result_cap = (result_len + out_size) * 2;
                    rb_str_resize(result, result_cap);
                }

                memcpy(RSTRING_PTR(result) + result_len, out_data, out_size);
                result_len += out_size;
                if (use_fiber) {
                    int did_yield = 0;
                    fiber_counter = fiber_maybe_yield(fiber_counter, out_size, &did_yield);
                    (void)did_yield;
                }
            }
        }
        rb_str_set_len(result, result_len);
        RB_GC_GUARD(chunk);
        return result;
    }
    case ALGO_LZ4: {
        VALUE result = rb_binary_str_buf_new(0);
        size_t result_len = 0;
        size_t result_cap = 0;

        while (slen > 0) {
            size_t space = LZ4_RING_BUFFER_SIZE - d->lz4_ring.pending;
            size_t copy = slen < space ? slen : space;

            if (d->lz4_ring.ring_offset + copy > LZ4_RING_BUFFER_TOTAL) {
                rb_raise(eError, "lz4: ring buffer overflow");
            }

            memcpy(d->lz4_ring.buf + d->lz4_ring.ring_offset, src, copy);
            d->lz4_ring.ring_offset += copy;
            d->lz4_ring.pending += copy;
            src += copy;
            slen -= copy;

            if (d->lz4_ring.pending >= (size_t)LZ4_RING_BUFFER_SIZE) {
                VALUE block = lz4_compress_ring_block(d);
                size_t blen = RSTRING_LEN(block);
                if (blen > 0) {
                    if (result_len + blen > result_cap) {
                        result_cap = (result_len + blen) * 2;
                        if (result_cap < 256)
                            result_cap = 256;
                        rb_str_resize(result, result_cap);
                    }
                    memcpy(RSTRING_PTR(result) + result_len, RSTRING_PTR(block), blen);
                    result_len += blen;
                }
            }
        }
        rb_str_set_len(result, result_len);
        RB_GC_GUARD(chunk);
        return result;
    }
    }
    return rb_binary_str_new("", 0);
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
        size_t result_cap = out_cap;
        VALUE result = rb_binary_str_buf_new(result_cap);
        size_t result_len = 0;
        size_t ret;

        do {
            if (result_len + out_cap > result_cap) {
                result_cap *= 2;
                rb_str_resize(result, result_cap);
            }

            ZSTD_outBuffer output = {RSTRING_PTR(result) + result_len, out_cap, 0};
            ret = ZSTD_flushStream(d->ctx.zstd, &output);
            if (ZSTD_isError(ret))
                rb_raise(eError, "zstd flush: %s", ZSTD_getErrorName(ret));
            result_len += output.pos;
        } while (ret > 0);

        rb_str_set_len(result, result_len);
        return result;
    }
    case ALGO_BROTLI: {
        size_t available_in = 0;
        const uint8_t *next_in = NULL;
        size_t result_cap = 1024;
        VALUE result = rb_binary_str_buf_new(result_cap);
        size_t result_len = 0;

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
            if (out_size > 0) {
                if (result_len + out_size > result_cap) {
                    result_cap = (result_len + out_size) * 2;
                    rb_str_resize(result, result_cap);
                }

                memcpy(RSTRING_PTR(result) + result_len, out_data, out_size);
                result_len += out_size;
            }
        } while (BrotliEncoderHasMoreOutput(d->ctx.brotli));

        rb_str_set_len(result, result_len);
        return result;
    }
    case ALGO_LZ4:
        return lz4_compress_ring_block(d);
    }
    return rb_binary_str_new("", 0);
}

static VALUE deflater_finish(VALUE self) {
    deflater_t *d;
    TypedData_Get_Struct(self, deflater_t, &deflater_type, d);
    if (d->closed)
        rb_raise(eStreamError, "stream is closed");
    if (d->finished)
        return rb_binary_str_new("", 0);
    d->finished = 1;

    switch (d->algo) {
    case ALGO_ZSTD: {
        size_t out_cap = ZSTD_CStreamOutSize();
        size_t result_cap = out_cap;
        VALUE result = rb_binary_str_buf_new(result_cap);
        size_t result_len = 0;
        size_t ret;

        do {
            if (result_len + out_cap > result_cap) {
                result_cap *= 2;
                rb_str_resize(result, result_cap);
            }

            ZSTD_outBuffer output = {RSTRING_PTR(result) + result_len, out_cap, 0};
            ret = ZSTD_endStream(d->ctx.zstd, &output);
            if (ZSTD_isError(ret))
                rb_raise(eError, "zstd end stream: %s", ZSTD_getErrorName(ret));
            result_len += output.pos;
        } while (ret > 0);

        rb_str_set_len(result, result_len);
        return result;
    }
    case ALGO_BROTLI: {
        size_t available_in = 0;
        const uint8_t *next_in = NULL;
        size_t result_cap = 1024;
        VALUE result = rb_binary_str_buf_new(result_cap);
        size_t result_len = 0;

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
            if (out_size > 0) {
                if (result_len + out_size > result_cap) {
                    result_cap = (result_len + out_size) * 2;
                    rb_str_resize(result, result_cap);
                }

                memcpy(RSTRING_PTR(result) + result_len, out_data, out_size);
                result_len += out_size;
            }
        } while (BrotliEncoderHasMoreOutput(d->ctx.brotli) ||
                 !BrotliEncoderIsFinished(d->ctx.brotli));

        rb_str_set_len(result, result_len);
        return result;
    }
    case ALGO_LZ4: {
        size_t result_cap = 256;
        VALUE result = rb_binary_str_buf_new(result_cap);
        size_t result_len = 0;

        if (d->lz4_ring.pending > 0) {
            VALUE block = lz4_compress_ring_block(d);
            size_t blen = RSTRING_LEN(block);
            if (blen > 0) {
                if (blen + 4 > result_cap) {
                    result_cap = blen + 4;
                    rb_str_resize(result, result_cap);
                }

                memcpy(RSTRING_PTR(result), RSTRING_PTR(block), blen);
                result_len = blen;
            }
        }

        if (result_len + 4 > result_cap) {
            result_cap = result_len + 4;
            rb_str_resize(result, result_cap);
        }

        char *out = RSTRING_PTR(result) + result_len;
        out[0] = out[1] = out[2] = out[3] = 0;
        result_len += 4;

        rb_str_set_len(result, result_len);
        return result;
    }
    }
    return rb_binary_str_new("", 0);
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
        d->lz4_ring.ring_offset = 0;
        d->lz4_ring.pending = 0;
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
        size_t offset;
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
        inf->lz4_buf.offset = 0;
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
        return rb_binary_str_new("", 0);

    switch (inf->algo) {
    case ALGO_ZSTD: {
        ZSTD_inBuffer input = {src, slen, 0};
        size_t out_cap = ZSTD_DStreamOutSize();
        size_t result_cap = out_cap > slen * 2 ? out_cap : slen * 2;
        VALUE result = rb_binary_str_buf_new(result_cap);
        size_t result_len = 0;
        int use_fiber = has_fiber_scheduler();
        size_t fiber_counter = 0;

        while (input.pos < input.size) {
            if (result_len + out_cap > result_cap) {
                result_cap = result_cap * 2;
                rb_str_resize(result, result_cap);
            }

            ZSTD_outBuffer output = {RSTRING_PTR(result) + result_len, out_cap, 0};
            size_t ret = ZSTD_decompressStream(inf->ctx.zstd, &output, &input);
            if (ZSTD_isError(ret))
                rb_raise(eDataError, "zstd decompress stream: %s", ZSTD_getErrorName(ret));
            result_len += output.pos;
            if (use_fiber) {
                int did_yield = 0;
                fiber_counter = fiber_maybe_yield(fiber_counter, output.pos, &did_yield);
                (void)did_yield;
            }
            if (ret == 0)
                break;
        }
        rb_str_set_len(result, result_len);
        RB_GC_GUARD(chunk);
        return result;
    }
    case ALGO_BROTLI: {
        size_t available_in = slen;
        const uint8_t *next_in = (const uint8_t *)src;
        size_t result_cap = slen * 2;
        if (result_cap < 1024)
            result_cap = 1024;
        VALUE result = rb_binary_str_buf_new(result_cap);
        size_t result_len = 0;
        int use_fiber = has_fiber_scheduler();
        size_t fiber_counter = 0;

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
            if (out_size > 0) {
                if (result_len + out_size > result_cap) {
                    result_cap = (result_len + out_size) * 2;
                    rb_str_resize(result, result_cap);
                }

                memcpy(RSTRING_PTR(result) + result_len, out_data, out_size);
                result_len += out_size;
                if (use_fiber) {
                    int did_yield = 0;
                    fiber_counter = fiber_maybe_yield(fiber_counter, out_size, &did_yield);
                    (void)did_yield;
                }
            }
            if (res == BROTLI_DECODER_RESULT_SUCCESS)
                break;
            if (res == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT && available_in == 0)
                break;
        }
        rb_str_set_len(result, result_len);
        RB_GC_GUARD(chunk);
        return result;
    }
    case ALGO_LZ4: {
        size_t data_len = inf->lz4_buf.len - inf->lz4_buf.offset;
        size_t needed = data_len + slen;

        if (inf->lz4_buf.offset > 0 && needed > inf->lz4_buf.cap) {
            if (data_len > 0)
                memmove(inf->lz4_buf.buf, inf->lz4_buf.buf + inf->lz4_buf.offset, data_len);
            inf->lz4_buf.offset = 0;
            inf->lz4_buf.len = data_len;
        } else if (inf->lz4_buf.offset > inf->lz4_buf.cap / 2) {
            if (data_len > 0)
                memmove(inf->lz4_buf.buf, inf->lz4_buf.buf + inf->lz4_buf.offset, data_len);
            inf->lz4_buf.offset = 0;
            inf->lz4_buf.len = data_len;
        }

        needed = inf->lz4_buf.len + slen;
        if (needed > inf->lz4_buf.cap) {
            inf->lz4_buf.cap = needed * 2;
            REALLOC_N(inf->lz4_buf.buf, char, inf->lz4_buf.cap);
        }
        memcpy(inf->lz4_buf.buf + inf->lz4_buf.len, src, slen);
        inf->lz4_buf.len += slen;

        size_t result_cap = slen * 4;
        if (result_cap < 256)
            result_cap = 256;
        VALUE result = rb_binary_str_buf_new(result_cap);
        size_t result_len = 0;
        int use_fiber = has_fiber_scheduler();
        size_t fiber_counter = 0;

        size_t pos = inf->lz4_buf.offset;
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

            if (result_len + orig_size > result_cap) {
                result_cap = (result_len + orig_size) * 2;
                rb_str_resize(result, result_cap);
            }

            int dsize =
                LZ4_decompress_safe(inf->lz4_buf.buf + pos + 8, RSTRING_PTR(result) + result_len,
                                    (int)comp_size, (int)orig_size);
            if (dsize < 0)
                rb_raise(eDataError, "lz4 stream decompress block failed");
            result_len += dsize;
            pos += 8 + comp_size;
            if (use_fiber) {
                int did_yield = 0;
                fiber_counter = fiber_maybe_yield(fiber_counter, (size_t)dsize, &did_yield);
                (void)did_yield;
            }
        }

        inf->lz4_buf.offset = pos;
        rb_str_set_len(result, result_len);
        RB_GC_GUARD(chunk);
        return result;
    }
    }
    return rb_binary_str_new("", 0);
}

static VALUE inflater_finish(VALUE self) {
    inflater_t *inf;
    TypedData_Get_Struct(self, inflater_t, &inflater_type, inf);
    if (inf->closed)
        rb_raise(eStreamError, "stream is closed");
    inf->finished = 1;
    return rb_binary_str_new("", 0);
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
        inf->lz4_buf.offset = 0;
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

static VALUE brotli_train_dictionary(int argc, VALUE *argv, VALUE self) {
    VALUE samples, opts;
    rb_scan_args(argc, argv, "1:", &samples, &opts);
    Check_Type(samples, T_ARRAY);

    VALUE size_val = Qnil;
    if (!NIL_P(opts)) {
        size_val = rb_hash_aref(opts, ID2SYM(rb_intern("size")));
    }

    size_t dict_capacity = NIL_P(size_val) ? 32768 : NUM2SIZET(size_val);

    long num_samples = RARRAY_LEN(samples);
    if (num_samples < 1)
        rb_raise(rb_eArgError, "need at least 1 sample for training");

    size_t total_size = 0;
    for (long i = 0; i < num_samples; i++) {
        VALUE s = rb_ary_entry(samples, i);
        StringValue(s);
        size_t slen = RSTRING_LEN(s);
        if (slen < 8) {
            rb_raise(rb_eArgError, "sample %ld is too small (%zu bytes), minimum is 8 bytes", i,
                     slen);
        }
        total_size += slen;
    }

    uint8_t *dict_buf = ALLOC_N(uint8_t, dict_capacity);
    if (!dict_buf) {
        rb_raise(eMemError, "failed to allocate memory for brotli dictionary training");
    }

    char *concat = ALLOC_N(char, total_size);
    if (!concat) {
        xfree(dict_buf);
        rb_raise(eMemError, "failed to allocate memory for brotli dictionary training");
    }

    size_t offset = 0;
    for (long i = 0; i < num_samples; i++) {
        VALUE s = rb_ary_entry(samples, i);
        StringValue(s);

        const char *str_ptr = RSTRING_PTR(s);
        size_t slen = RSTRING_LEN(s);

        if (offset + slen > total_size) {
            xfree(concat);
            xfree(dict_buf);
            rb_raise(eError, "buffer overflow during concatenation");
        }

        memcpy(concat + offset, str_ptr, slen);
        offset += slen;

        RB_GC_GUARD(s);
    }

    size_t dict_size = total_size < dict_capacity ? total_size : dict_capacity;
    memcpy(dict_buf, concat, dict_size);
    xfree(concat);

    VALUE dict_obj = rb_obj_alloc(cDictionary);
    dictionary_t *d;
    TypedData_Get_Struct(dict_obj, dictionary_t, &dictionary_type, d);
    memset(d, 0, sizeof(*d));
    d->algo = ALGO_BROTLI;
    d->data = dict_buf;
    d->size = dict_size;
    return dict_obj;
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
    binary_encoding = rb_ascii8bit_encoding();
    crc32_init_tables();

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
    rb_define_singleton_method(cDictionary, "load", dict_load, -1);
    rb_define_method(cDictionary, "save", dict_save, 1);
    rb_define_method(cDictionary, "algo", dict_algo, 0);
    rb_define_method(cDictionary, "size", dict_size, 0);
    rb_define_singleton_method(mBrotli, "train_dictionary", brotli_train_dictionary, -1);
}
