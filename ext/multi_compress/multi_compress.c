#include <ruby.h>
#include <ruby/encoding.h>
#include <ruby/thread.h>
#include <ruby/fiber/scheduler.h>
#include <brotli/decode.h>
#include <brotli/encode.h>
#include <lz4.h>
#include <lz4hc.h>
#include <lz4frame.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zstd.h>
#include <zdict.h>

#define MAX_DECOMPRESS_SIZE   (512ULL * 1024 * 1024)
#define DEFAULT_MAX_RATIO     1000ULL
#define RATIO_MIN_INPUT_BYTES 1024ULL
#define DICT_FILE_MAX_SIZE    (32ULL * 1024 * 1024)

#if defined(__GNUC__) || defined(__clang__)
#define MC_ALWAYS_INLINE static inline __attribute__((always_inline))
#else
#define MC_ALWAYS_INLINE static inline
#endif

#if defined(__GNUC__) || defined(__clang__)
#define MC_LIKELY(x)   __builtin_expect(!!(x), 1)
#define MC_UNLIKELY(x) __builtin_expect(!!(x), 0)
#else
#define MC_LIKELY(x)   (x)
#define MC_UNLIKELY(x) (x)
#endif

typedef struct {
    size_t gvl_unlock_threshold;
    size_t fiber_yield_chunk;
    size_t fiber_stream_threshold;
} algo_policy_t;

static const algo_policy_t ZSTD_POLICY = {
    .gvl_unlock_threshold = 64 * 1024,
    .fiber_yield_chunk = 64 * 1024,
    .fiber_stream_threshold = 32 * 1024,
};

static const algo_policy_t LZ4_POLICY = {
    .gvl_unlock_threshold = 128 * 1024,
    .fiber_yield_chunk = 128 * 1024,
    .fiber_stream_threshold = 64 * 1024,
};

static const algo_policy_t BROTLI_POLICY = {
    .gvl_unlock_threshold = 16 * 1024,
    .fiber_yield_chunk = 16 * 1024,
    .fiber_stream_threshold = 8 * 1024,
};

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
static struct {
    ID zstd, lz4, brotli;
    ID algo, algorithm, level, dictionary, size, format, block, frame;
    ID max_output_size, max_ratio;
    ID fastest, default_, best;
    ID yield_, join;
    ID ivar_dictionary;
} id_cache;

static struct {
    VALUE zstd, lz4, brotli;
    VALUE algo, algorithm, level, dictionary, size, format, block, frame;
    VALUE max_output_size, max_ratio;
} sym_cache;

typedef enum { ALGO_ZSTD = 0, ALGO_LZ4 = 1, ALGO_BROTLI = 2 } compress_algo_t;
typedef enum { LZ4_FORMAT_BLOCK = 0, LZ4_FORMAT_FRAME = 1 } lz4_format_t;

#define MC_NUM_ALGOS 3

static pthread_once_t zstd_tls_once = PTHREAD_ONCE_INIT;
static pthread_key_t zstd_cctx_key;
static pthread_key_t zstd_dctx_key;

static void zstd_tls_free_cctx(void *ptr) {
    if (ptr)
        ZSTD_freeCCtx((ZSTD_CCtx *)ptr);
}

static void zstd_tls_free_dctx(void *ptr) {
    if (ptr)
        ZSTD_freeDCtx((ZSTD_DCtx *)ptr);
}

static void zstd_tls_init(void) {
    if (pthread_key_create(&zstd_cctx_key, zstd_tls_free_cctx) != 0)
        abort();
    if (pthread_key_create(&zstd_dctx_key, zstd_tls_free_dctx) != 0)
        abort();
}

static ZSTD_CCtx *zstd_tls_get_cctx(void) {
    pthread_once(&zstd_tls_once, zstd_tls_init);

    ZSTD_CCtx *cctx = (ZSTD_CCtx *)pthread_getspecific(zstd_cctx_key);
    if (cctx)
        return cctx;

    cctx = ZSTD_createCCtx();
    if (!cctx)
        return NULL;

    if (pthread_setspecific(zstd_cctx_key, cctx) != 0) {
        ZSTD_freeCCtx(cctx);
        return NULL;
    }

    return cctx;
}

static ZSTD_DCtx *zstd_tls_get_dctx(void) {
    pthread_once(&zstd_tls_once, zstd_tls_init);

    ZSTD_DCtx *dctx = (ZSTD_DCtx *)pthread_getspecific(zstd_dctx_key);
    if (dctx)
        return dctx;

    dctx = ZSTD_createDCtx();
    if (!dctx)
        return NULL;

    if (pthread_setspecific(zstd_dctx_key, dctx) != 0) {
        ZSTD_freeDCtx(dctx);
        return NULL;
    }

    return dctx;
}

static size_t zstd_compress_cached(char *dst, size_t dst_cap, const char *src, size_t src_len,
                                   int level, ZSTD_CDict *cdict, int *ctx_error) {
    *ctx_error = 0;

    ZSTD_CCtx *cctx = zstd_tls_get_cctx();
    if (!cctx) {
        *ctx_error = 1;
        return 0;
    }

    if (cdict)
        return ZSTD_compress_usingCDict(cctx, dst, dst_cap, src, src_len, cdict);

    return ZSTD_compressCCtx(cctx, dst, dst_cap, src, src_len, level);
}

static size_t zstd_decompress_cached(void *dst, size_t dst_cap, const void *src, size_t src_len,
                                     ZSTD_DDict *ddict, int *ctx_error) {
    *ctx_error = 0;

    ZSTD_DCtx *dctx = zstd_tls_get_dctx();
    if (!dctx) {
        *ctx_error = 1;
        return 0;
    }

    if (ddict)
        return ZSTD_decompress_usingDDict(dctx, dst, dst_cap, src, src_len, ddict);

    return ZSTD_decompressDCtx(dctx, dst, dst_cap, src, src_len);
}

_Static_assert(ALGO_BROTLI == MC_NUM_ALGOS - 1,
               "compress_algo_t must be contiguous [0..MC_NUM_ALGOS-1]");

typedef struct dictionary_s dictionary_t;
static const rb_data_type_t dictionary_type;

static void init_id_cache(void) {
    id_cache.zstd = rb_intern("zstd");
    id_cache.lz4 = rb_intern("lz4");
    id_cache.brotli = rb_intern("brotli");
    id_cache.algo = rb_intern("algo");
    id_cache.algorithm = rb_intern("algorithm");
    id_cache.level = rb_intern("level");
    id_cache.dictionary = rb_intern("dictionary");
    id_cache.size = rb_intern("size");
    id_cache.format = rb_intern("format");
    id_cache.block = rb_intern("block");
    id_cache.frame = rb_intern("frame");
    id_cache.max_output_size = rb_intern("max_output_size");
    id_cache.max_ratio = rb_intern("max_ratio");
    id_cache.fastest = rb_intern("fastest");
    id_cache.default_ = rb_intern("default");
    id_cache.best = rb_intern("best");
    id_cache.yield_ = rb_intern("yield");
    id_cache.join = rb_intern("join");
    id_cache.ivar_dictionary = rb_intern("@dictionary");

    sym_cache.zstd = ID2SYM(id_cache.zstd);
    sym_cache.lz4 = ID2SYM(id_cache.lz4);
    sym_cache.brotli = ID2SYM(id_cache.brotli);
    sym_cache.algo = ID2SYM(id_cache.algo);
    sym_cache.algorithm = ID2SYM(id_cache.algorithm);
    sym_cache.level = ID2SYM(id_cache.level);
    sym_cache.dictionary = ID2SYM(id_cache.dictionary);
    sym_cache.size = ID2SYM(id_cache.size);
    sym_cache.format = ID2SYM(id_cache.format);
    sym_cache.block = ID2SYM(id_cache.block);
    sym_cache.frame = ID2SYM(id_cache.frame);
    sym_cache.max_output_size = ID2SYM(id_cache.max_output_size);
    sym_cache.max_ratio = ID2SYM(id_cache.max_ratio);
}

typedef struct {
    VALUE algo;
    VALUE level;
    VALUE dictionary;
    VALUE size;
    VALUE format;
    VALUE max_output_size;
    VALUE max_ratio;
    int saw_algorithm_keyword;
} mc_opts_t;

static inline void mc_opts_init(mc_opts_t *opts) {
    opts->algo = Qnil;
    opts->level = Qnil;
    opts->dictionary = Qnil;
    opts->size = Qnil;
    opts->format = Qnil;
    opts->max_output_size = Qundef;
    opts->max_ratio = Qundef;
    opts->saw_algorithm_keyword = 0;
}

static int mc_opts_parse_i(VALUE key, VALUE value, VALUE arg) {
    mc_opts_t *opts = (mc_opts_t *)arg;

    if (!SYMBOL_P(key))
        return ST_CONTINUE;

    ID id = SYM2ID(key);
    if (id == id_cache.algo) {
        opts->algo = value;
    } else if (id == id_cache.level) {
        opts->level = value;
    } else if (id == id_cache.dictionary) {
        opts->dictionary = value;
    } else if (id == id_cache.size) {
        opts->size = value;
    } else if (id == id_cache.format) {
        opts->format = value;
    } else if (id == id_cache.max_output_size) {
        opts->max_output_size = value;
    } else if (id == id_cache.max_ratio) {
        opts->max_ratio = value;
    } else if (id == id_cache.algorithm) {
        opts->saw_algorithm_keyword = 1;
    }

    return ST_CONTINUE;
}

static inline void mc_parse_opts(VALUE opts_hash, mc_opts_t *opts) {
    mc_opts_init(opts);
    if (NIL_P(opts_hash))
        return;
    Check_Type(opts_hash, T_HASH);
    rb_hash_foreach(opts_hash, mc_opts_parse_i, (VALUE)opts);
}

static inline void scan_one_required_keywords(int argc, VALUE *argv, VALUE *arg, VALUE *opts) {
    if (argc == 1) {
        *arg = argv[0];
        *opts = Qnil;
        return;
    }

    if (argc == 2 && rb_keyword_given_p()) {
        *arg = argv[0];
        *opts = argv[1];
        Check_Type(*opts, T_HASH);
        return;
    }

    rb_error_arity(argc, 1, 1);
}

static inline void scan_zero_required_keywords(int argc, VALUE *argv, VALUE *opts) {
    if (argc == 0) {
        *opts = Qnil;
        return;
    }

    if (argc == 1 && rb_keyword_given_p()) {
        *opts = argv[0];
        Check_Type(*opts, T_HASH);
        return;
    }

    rb_error_arity(argc, 0, 0);
}

enum { LZ4_FRAME_MAGIC_LEN = 4 };
static const uint8_t LZ4_FRAME_MAGIC[LZ4_FRAME_MAGIC_LEN] = {0x04, 0x22, 0x4D, 0x18};

static inline int is_lz4_frame_magic(const uint8_t *data, size_t len) {
    return len >= LZ4_FRAME_MAGIC_LEN && memcmp(data, LZ4_FRAME_MAGIC, LZ4_FRAME_MAGIC_LEN) == 0;
}

static lz4_format_t parse_lz4_format(const mc_opts_t *opts, compress_algo_t algo,
                                     int explicit_algo) {
    VALUE format_val = opts->format;
    if (format_val == Qundef || NIL_P(format_val))
        return LZ4_FORMAT_BLOCK;
    if (explicit_algo && algo != ALGO_LZ4)
        rb_raise(eUnsupportedError, "format is only supported for algo: :lz4");
    if (!SYMBOL_P(format_val))
        rb_raise(rb_eTypeError, "format must be a Symbol (:block or :frame)");
    ID id = SYM2ID(format_val);
    if (id == id_cache.block)
        return LZ4_FORMAT_BLOCK;
    if (id == id_cache.frame)
        return LZ4_FORMAT_FRAME;
    rb_raise(rb_eArgError, "Unknown LZ4 format: %s", rb_id2name(id));
    return LZ4_FORMAT_BLOCK;
}

static inline void reject_algorithm_keyword(const mc_opts_t *opts) {
    if (opts->saw_algorithm_keyword) {
        rb_raise(rb_eArgError, "unknown keyword: :algorithm (use :algo)");
    }
}

static inline dictionary_t *opt_dictionary(VALUE dict_val) {
    dictionary_t *dict;

    if (NIL_P(dict_val))
        return NULL;
    if (!rb_obj_is_kind_of(dict_val, cDictionary)) {
        rb_raise(rb_eTypeError, "dictionary must be a MultiCompress::Dictionary");
    }

    TypedData_Get_Struct(dict_val, dictionary_t, &dictionary_type, dict);
    return dict;
}

static inline void raise_if_path_has_null_byte(VALUE path) {
    if (memchr(RSTRING_PTR(path), '\0', (size_t)RSTRING_LEN(path)) != NULL) {
        rb_raise(rb_eArgError, "path contains null byte");
    }
}

static inline void join_thread(VALUE thread) {
    rb_funcall(thread, id_cache.join, 0);
}

static inline void scheduler_yield(VALUE scheduler) {
    rb_funcall(scheduler, id_cache.yield_, 0);
}

static inline VALUE dictionary_ivar_get(VALUE self) {
    return rb_ivar_get(self, id_cache.ivar_dictionary);
}

static inline void dictionary_ivar_set(VALUE self, VALUE dictionary) {
    rb_ivar_set(self, id_cache.ivar_dictionary, dictionary);
}

MC_ALWAYS_INLINE uint32_t read_le_u32(const uint8_t *restrict p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

MC_ALWAYS_INLINE void write_le_u32(uint8_t *restrict p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static inline const algo_policy_t *algo_policy(compress_algo_t algo) {
    switch (algo) {
    case ALGO_ZSTD:
        return &ZSTD_POLICY;
    case ALGO_LZ4:
        return &LZ4_POLICY;
    case ALGO_BROTLI:
        return &BROTLI_POLICY;
    }
    return &ZSTD_POLICY;
}

static compress_algo_t sym_to_algo(VALUE sym) {
    if (!SYMBOL_P(sym)) {
        rb_raise(rb_eTypeError, "algo must be a Symbol (:zstd, :lz4, :brotli)");
    }

    ID id = SYM2ID(sym);
    if (id == id_cache.zstd)
        return ALGO_ZSTD;
    if (id == id_cache.lz4)
        return ALGO_LZ4;
    if (id == id_cache.brotli)
        return ALGO_BROTLI;
    rb_raise(rb_eArgError, "Unknown algorithm: %s", rb_id2name(id));
    return ALGO_ZSTD;
}

static inline VALUE algo_to_sym(compress_algo_t algo) {
    switch (algo) {
    case ALGO_ZSTD:
        return sym_cache.zstd;
    case ALGO_LZ4:
        return sym_cache.lz4;
    case ALGO_BROTLI:
        return sym_cache.brotli;
    }
    return Qnil;
}

typedef struct {
    int min, max, fastest, default_, best;
    const char *name;
} level_spec_t;

static const level_spec_t level_spec[] = {
    [ALGO_ZSTD] = {.min = 1, .max = 22, .fastest = 1, .default_ = 3, .best = 19, .name = "zstd"},
    [ALGO_LZ4] = {.min = 1, .max = 16, .fastest = 1, .default_ = 1, .best = 16, .name = "lz4"},
    [ALGO_BROTLI] =
        {.min = 0, .max = 11, .fastest = 0, .default_ = 6, .best = 11, .name = "brotli"},
};
_Static_assert(sizeof(level_spec) / sizeof(level_spec[0]) == MC_NUM_ALGOS,
               "level_spec must cover every compress_algo_t value");

static int resolve_level(compress_algo_t algo, VALUE level_val) {
    const level_spec_t *spec = &level_spec[algo];

    if (NIL_P(level_val))
        return spec->default_;

    if (SYMBOL_P(level_val)) {
        ID id = SYM2ID(level_val);
        if (id == id_cache.fastest)
            return spec->fastest;
        if (id == id_cache.default_)
            return spec->default_;
        if (id == id_cache.best)
            return spec->best;
        rb_raise(eLevelError, "Unknown named level: %s", rb_id2name(id));
    }

    const int level = NUM2INT(level_val);
    if (level < spec->min || level > spec->max)
        rb_raise(eLevelError, "%s level must be %d..%d, got %d", spec->name, spec->min, spec->max,
                 level);
    return level;
}

static compress_algo_t detect_algo(const uint8_t *data, size_t len) {
    enum { ZSTD_MAGIC_LEN = 4 };
    static const uint8_t ZSTD_MAGIC[ZSTD_MAGIC_LEN] = {0x28, 0xB5, 0x2F, 0xFD};
    enum { LZ4_BLOCK_SANITY_MAX = 256U * 1024 * 1024 };

    if (is_lz4_frame_magic(data, len)) {
        return ALGO_LZ4;
    }

    if (len >= ZSTD_MAGIC_LEN && memcmp(data, ZSTD_MAGIC, ZSTD_MAGIC_LEN) == 0) {
        return ALGO_ZSTD;
    }

    if (len >= 12) {
        size_t pos = 0;
        int saw_block = 0;
        while (pos + 4 <= len) {
            uint32_t orig = read_le_u32(data + pos);
            if (orig == 0) {
                if (saw_block && pos + 4 == len)
                    return ALGO_LZ4;
                break;
            }
            if (pos + 8 > len)
                break;
            uint32_t comp = read_le_u32(data + pos + 4);
            if (comp == 0 || orig > LZ4_BLOCK_SANITY_MAX || orig > (uint32_t)INT_MAX)
                break;
            if (comp > LZ4_BLOCK_SANITY_MAX || comp > (uint32_t)LZ4_compressBound((int)orig))
                break;
            if (pos + 8 + (size_t)comp > len)
                break;
            saw_block = 1;
            pos += 8 + (size_t)comp;
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

static inline VALUE rb_binary_str_buf_reserve(long capa) {
    VALUE str = rb_str_buf_new(capa);
    rb_enc_associate(str, binary_encoding);
    return str;
}

static inline void grow_binary_str(VALUE str, size_t cur_len, size_t new_cap) {
    size_t cur_cap = (size_t)rb_str_capacity(str);
    if (new_cap <= cur_cap)
        return;
    rb_str_set_len(str, (long)cur_len);
    rb_str_modify_expand(str, (long)(new_cap - cur_len));
}

typedef struct {
    size_t max_output_size;
    int max_ratio_enabled;
    unsigned long long max_ratio;
} limits_config_t;

static void limits_config_init(limits_config_t *limits) {
    limits->max_output_size = (size_t)MAX_DECOMPRESS_SIZE;
    limits->max_ratio_enabled = 1;
    limits->max_ratio = DEFAULT_MAX_RATIO;
}

static void limits_config_apply_parsed(const mc_opts_t *opts, limits_config_t *limits) {
    VALUE val = opts->max_output_size;
    if (val != Qundef && !NIL_P(val)) {
        size_t max_output_size = NUM2SIZET(val);
        if (max_output_size == 0)
            rb_raise(rb_eArgError, "max_output_size must be greater than 0");
        limits->max_output_size = max_output_size;
    }

    val = opts->max_ratio;
    if (val == Qundef)
        return;
    if (NIL_P(val)) {
        limits->max_ratio_enabled = 0;
        limits->max_ratio = 0;
        return;
    }

    unsigned long long max_ratio = NUM2ULL(val);
    if (max_ratio == 0)
        rb_raise(rb_eArgError, "max_ratio must be greater than 0 or nil");
    limits->max_ratio_enabled = 1;
    limits->max_ratio = max_ratio;
}

static void parse_limits_from_parsed_opts(const mc_opts_t *opts, limits_config_t *limits) {
    limits_config_init(limits);
    limits_config_apply_parsed(opts, limits);
}

static inline size_t checked_add_size(size_t left, size_t right, const char *message) {
    if (MC_UNLIKELY(SIZE_MAX - left < right))
        rb_raise(eDataError, "%s", message);
    return left + right;
}

static size_t ratio_limit_bytes(size_t total_input, unsigned long long max_ratio) {
    if (total_input == 0)
        return SIZE_MAX;
    if (max_ratio > ((unsigned long long)SIZE_MAX / (unsigned long long)total_input))
        return SIZE_MAX;
    return total_input * (size_t)max_ratio;
}

static inline void enforce_output_and_ratio_limits(size_t total_output, size_t total_input,
                                                   size_t max_output_size, int max_ratio_enabled,
                                                   unsigned long long max_ratio) {
    if (MC_UNLIKELY(total_output > max_output_size)) {
        rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)", max_output_size);
    }

    if (!max_ratio_enabled || total_input < RATIO_MIN_INPUT_BYTES)
        return;

    size_t ratio_limit = ratio_limit_bytes(total_input, max_ratio);
    if (MC_UNLIKELY(total_output > ratio_limit)) {
        size_t ratio = total_input == 0 ? 0 : (total_output / total_input);
        rb_raise(eDataError, "decompression ratio exceeds limit (ratio=%zu, max=%llu)", ratio,
                 max_ratio);
    }
}

static VALUE current_fiber_scheduler(void) {
    VALUE sched = rb_fiber_scheduler_current();
    if (sched == Qnil || sched == Qfalse)
        return Qnil;
    return sched;
}

static int has_fiber_scheduler(void) {
    return current_fiber_scheduler() != Qnil;
}

static void unblock_noop(void *arg) {
    (void)arg;
}

static inline void run_without_gvl(void *(*func)(void *), void *arg) {
    rb_thread_call_without_gvl(func, arg, unblock_noop, NULL);
}

typedef struct {
    void *(*func)(void *);
    void *arg;
    size_t arg_size;
    VALUE thread;
} fiber_worker_ctx_t;

typedef enum {
    WORK_EXEC_DIRECT = 0,
    WORK_EXEC_NOGVL = 1,
    WORK_EXEC_FIBER = 2,
} work_exec_mode_t;

static void fiber_worker_mark(void *ptr) {
    fiber_worker_ctx_t *c = (fiber_worker_ctx_t *)ptr;
    if (!c)
        return;
    rb_gc_mark(c->thread);
}

static void fiber_worker_free(void *ptr) {
    fiber_worker_ctx_t *c = (fiber_worker_ctx_t *)ptr;
    if (!c)
        return;
    if (c->arg)
        xfree(c->arg);
    xfree(c);
}

static size_t fiber_worker_memsize(const void *ptr) {
    const fiber_worker_ctx_t *c = (const fiber_worker_ctx_t *)ptr;
    return sizeof(fiber_worker_ctx_t) + (c ? c->arg_size : 0);
}

static const rb_data_type_t fiber_worker_type = {
    "MultiCompress/FiberWorker",
    {fiber_worker_mark, fiber_worker_free, fiber_worker_memsize},
    0,
    0,
    RUBY_TYPED_FREE_IMMEDIATELY};

static inline work_exec_mode_t select_fiber_or_direct_mode(VALUE scheduler, size_t work_size,
                                                           size_t fiber_threshold) {
    if (scheduler != Qnil && work_size >= fiber_threshold)
        return WORK_EXEC_FIBER;
    return WORK_EXEC_DIRECT;
}

static inline work_exec_mode_t select_fiber_nogvl_or_direct_mode(VALUE scheduler, size_t work_size,
                                                                 size_t fiber_threshold,
                                                                 size_t nogvl_threshold) {
    if (scheduler != Qnil && work_size >= fiber_threshold)
        return WORK_EXEC_FIBER;
    if (scheduler == Qnil && work_size >= nogvl_threshold)
        return WORK_EXEC_NOGVL;
    return WORK_EXEC_DIRECT;
}

static VALUE fiber_worker_new(void *(*func)(void *), const void *arg, size_t arg_size) {
    fiber_worker_ctx_t *c;
    VALUE worker = TypedData_Make_Struct(rb_cObject, fiber_worker_ctx_t, &fiber_worker_type, c);
    memset(c, 0, sizeof(*c));
    c->func = func;
    c->arg_size = arg_size;
    if (arg_size > 0) {
        c->arg = xmalloc(arg_size);
        memcpy(c->arg, arg, arg_size);
    }
    c->thread = Qnil;
    return worker;
}

static void *fiber_worker_nogvl(void *arg) {
    fiber_worker_ctx_t *c = (fiber_worker_ctx_t *)arg;
    c->func(c->arg);
    return NULL;
}

static VALUE fiber_worker_thread(void *arg) {
    fiber_worker_ctx_t *c = (fiber_worker_ctx_t *)arg;
    rb_thread_call_without_gvl(fiber_worker_nogvl, c, unblock_noop, NULL);
    return Qnil;
}

static VALUE fiber_worker_wait(VALUE worker) {
    fiber_worker_ctx_t *c;
    TypedData_Get_Struct(worker, fiber_worker_ctx_t, &fiber_worker_type, c);
    c->thread = rb_thread_create(fiber_worker_thread, c);
    join_thread(c->thread);
    return Qnil;
}

static VALUE fiber_worker_join_ensure(VALUE worker) {
    fiber_worker_ctx_t *c;
    TypedData_Get_Struct(worker, fiber_worker_ctx_t, &fiber_worker_type, c);
    if (!NIL_P(c->thread))
        join_thread(c->thread);
    return Qnil;
}

static void run_via_fiber_worker(void *(*func)(void *), void *arg, size_t arg_size) {
    VALUE worker = fiber_worker_new(func, arg, arg_size);
    rb_ensure(fiber_worker_wait, worker, fiber_worker_join_ensure, worker);
    fiber_worker_ctx_t *c;
    TypedData_Get_Struct(worker, fiber_worker_ctx_t, &fiber_worker_type, c);
    if (arg_size > 0)
        memcpy(arg, c->arg, arg_size);
    RB_GC_GUARD(worker);
}

static inline void run_with_exec_mode(work_exec_mode_t mode, void *(*func)(void *), void *arg,
                                      size_t arg_size) {
    switch (mode) {
    case WORK_EXEC_FIBER:
        run_via_fiber_worker(func, arg, arg_size);
        break;
    case WORK_EXEC_NOGVL:
        run_without_gvl(func, arg);
        break;
    case WORK_EXEC_DIRECT:
    default:
        func(arg);
        break;
    }
}

#define RUN_VIA_FIBER_WORKER(func, arg)     run_via_fiber_worker((func), &(arg), sizeof(arg))
#define RUN_WITH_EXEC_MODE(mode, func, arg) run_with_exec_mode((mode), (func), &(arg), sizeof(arg))

static inline size_t fiber_maybe_yield(size_t bytes_since_yield, size_t just_processed,
                                       size_t yield_chunk, int *did_yield) {
    *did_yield = 0;
    bytes_since_yield += just_processed;
    if (bytes_since_yield >= yield_chunk) {
        VALUE scheduler = current_fiber_scheduler();
        if (scheduler != Qnil) {
            scheduler_yield(scheduler);
            *did_yield = 1;
        }
        return 0;
    }
    return bytes_since_yield;
}

#define DICT_ZSTD_MIN_LEVEL   1
#define DICT_ZSTD_MAX_LEVEL   22
#define DICT_CDICT_CACHE_SIZE (DICT_ZSTD_MAX_LEVEL + 1)
_Static_assert(DICT_CDICT_CACHE_SIZE > DICT_ZSTD_MAX_LEVEL,
               "CDict cache needs one slot for every accepted zstd level");

#if defined(__GNUC__) || defined(__clang__)
#define MC_HAS_ATOMIC_PTR             1
#define MC_ATOMIC_LOAD_PTR(ptr)       __atomic_load_n((ptr), __ATOMIC_ACQUIRE)
#define MC_ATOMIC_STORE_PTR(ptr, val) __atomic_store_n((ptr), (val), __ATOMIC_RELEASE)
#else
#define MC_HAS_ATOMIC_PTR 0
#endif

struct dictionary_s {
    compress_algo_t algo;
    uint8_t *data;
    size_t size;
    pthread_mutex_t cache_mutex;

    ZSTD_CDict *cdict_cache[DICT_CDICT_CACHE_SIZE];

    ZSTD_DDict *ddict;
};

static void dict_free(void *ptr) {
    dictionary_t *dict = (dictionary_t *)ptr;
    if (!dict)
        return;
    for (int i = DICT_ZSTD_MIN_LEVEL; i <= DICT_ZSTD_MAX_LEVEL; i++) {
        if (dict->cdict_cache[i])
            ZSTD_freeCDict(dict->cdict_cache[i]);
    }
    if (dict->ddict)
        ZSTD_freeDDict(dict->ddict);
    pthread_mutex_destroy(&dict->cache_mutex);
    if (dict->data)
        xfree(dict->data);
    xfree(dict);
}

static size_t dict_memsize(const void *ptr) {
    const dictionary_t *d = (const dictionary_t *)ptr;
    if (!d)
        return 0;

    size_t total = sizeof(dictionary_t) + d->size;
    if (d->algo == ALGO_ZSTD) {
        for (int i = DICT_ZSTD_MIN_LEVEL; i <= DICT_ZSTD_MAX_LEVEL; i++) {
            if (d->cdict_cache[i])
                total += ZSTD_sizeof_CDict(d->cdict_cache[i]);
        }
        if (d->ddict)
            total += ZSTD_sizeof_DDict(d->ddict);
    }
    return total;
}

static const rb_data_type_t dictionary_type = {
    "Compress::Dictionary", {NULL, dict_free, dict_memsize}, 0, 0, RUBY_TYPED_FREE_IMMEDIATELY};

static VALUE dict_alloc(VALUE klass) {
    dictionary_t *d = ALLOC(dictionary_t);
    memset(d, 0, sizeof(dictionary_t));
    if (pthread_mutex_init(&d->cache_mutex, NULL) != 0) {
        xfree(d);
        rb_raise(eMemError, "failed to initialize dictionary cache mutex");
    }
    return TypedData_Wrap_Struct(klass, &dictionary_type, d);
}

static ZSTD_CDict *dict_get_cdict(dictionary_t *dict, int level) {
    if (MC_UNLIKELY(level < DICT_ZSTD_MIN_LEVEL || level > DICT_ZSTD_MAX_LEVEL))
        rb_raise(eLevelError, "zstd level must be %d..%d, got %d", DICT_ZSTD_MIN_LEVEL,
                 DICT_ZSTD_MAX_LEVEL, level);

    ZSTD_CDict *existing;
#if MC_HAS_ATOMIC_PTR
    existing = MC_ATOMIC_LOAD_PTR(&dict->cdict_cache[level]);
#else
    pthread_mutex_lock(&dict->cache_mutex);
    existing = dict->cdict_cache[level];
    pthread_mutex_unlock(&dict->cache_mutex);
#endif
    if (existing)
        return existing;

    ZSTD_CDict *cdict = ZSTD_createCDict(dict->data, dict->size, level);
    if (!cdict)
        return NULL;

    pthread_mutex_lock(&dict->cache_mutex);
    existing = dict->cdict_cache[level];
    if (!existing) {
#if MC_HAS_ATOMIC_PTR
        MC_ATOMIC_STORE_PTR(&dict->cdict_cache[level], cdict);
#else
        dict->cdict_cache[level] = cdict;
#endif
        pthread_mutex_unlock(&dict->cache_mutex);
        return cdict;
    }

    pthread_mutex_unlock(&dict->cache_mutex);
    ZSTD_freeCDict(cdict);
    return existing;
}

static ZSTD_DDict *dict_get_ddict(dictionary_t *dict) {
    ZSTD_DDict *existing;
#if MC_HAS_ATOMIC_PTR
    existing = MC_ATOMIC_LOAD_PTR(&dict->ddict);
#else
    pthread_mutex_lock(&dict->cache_mutex);
    existing = dict->ddict;
    pthread_mutex_unlock(&dict->cache_mutex);
#endif
    if (existing)
        return existing;

    ZSTD_DDict *created = ZSTD_createDDict(dict->data, dict->size);
    if (!created)
        return NULL;

    pthread_mutex_lock(&dict->cache_mutex);
    existing = dict->ddict;
    if (!existing) {
#if MC_HAS_ATOMIC_PTR
        MC_ATOMIC_STORE_PTR(&dict->ddict, created);
#else
        dict->ddict = created;
#endif
        pthread_mutex_unlock(&dict->cache_mutex);
        return created;
    }

    pthread_mutex_unlock(&dict->cache_mutex);
    ZSTD_freeDDict(created);
    return existing;
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
    a->result =
        zstd_compress_cached(a->dst, a->dst_cap, a->src, a->src_len, a->level, a->cdict, &a->error);
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
    a->result = zstd_decompress_cached(a->dst, a->dst_cap, a->src, a->src_len, a->ddict, &a->error);
    return NULL;
}

typedef struct {
    const uint8_t *src;
    size_t src_len;
    char *dst;
    size_t out_offset;
    int error;
    char err_msg[64];
} lz4_decompress_all_args_t;

static void *lz4_decompress_all_nogvl(void *arg) {
    lz4_decompress_all_args_t *a = (lz4_decompress_all_args_t *)arg;
    const uint8_t *restrict src = a->src;
    size_t slen = a->src_len;
    char *restrict out_ptr = a->dst;
    size_t out_offset = 0;
    size_t pos = 0;

    while (pos + 4 <= slen) {
        uint32_t orig_size = read_le_u32(src + pos);
        if (orig_size == 0)
            break;
        uint32_t comp_size = read_le_u32(src + pos + 4);

        int dsize = LZ4_decompress_safe((const char *)(src + pos + 8), out_ptr + out_offset,
                                        (int)comp_size, (int)orig_size);
        if (MC_UNLIKELY(dsize < 0)) {
            a->error = 1;
            static const char kLz4FailMsg[] = "lz4 decompress failed";
            memcpy(a->err_msg, kLz4FailMsg, sizeof(kLz4FailMsg));
            return NULL;
        }

        out_offset += (size_t)dsize;
        pos += 8 + comp_size;
    }

    a->out_offset = out_offset;
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

typedef struct {
    const void *src;
    size_t src_len;
    void *dst;
    size_t dst_cap;
    size_t result;
    size_t error_code;
} lz4frame_compress_args_t;

typedef struct {
    const void *src;
    size_t src_len;
    void *dst;
    size_t dst_cap;
    size_t result;
    size_t error_code;
} lz4frame_decompress_args_t;

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

static void *lz4frame_compress_nogvl(void *arg) {
    lz4frame_compress_args_t *a = (lz4frame_compress_args_t *)arg;
    LZ4F_preferences_t prefs;
    memset(&prefs, 0, sizeof(prefs));
    prefs.frameInfo.blockChecksumFlag = LZ4F_blockChecksumEnabled;
    prefs.frameInfo.contentChecksumFlag = LZ4F_contentChecksumEnabled;
    a->result = LZ4F_compressFrame(a->dst, a->dst_cap, a->src, a->src_len, &prefs);
    a->error_code = LZ4F_isError(a->result) ? a->result : 0;
    return NULL;
}

static void *lz4frame_decompress_nogvl(void *arg) {
    lz4frame_decompress_args_t *a = (lz4frame_decompress_args_t *)arg;
    LZ4F_dctx *dctx = NULL;
    size_t rc = LZ4F_createDecompressionContext(&dctx, LZ4F_VERSION);
    if (LZ4F_isError(rc)) {
        a->result = 0;
        a->error_code = rc;
        return NULL;
    }

    const uint8_t *src = (const uint8_t *)a->src;
    uint8_t *dst = (uint8_t *)a->dst;
    size_t src_pos = 0;
    size_t dst_pos = 0;
    size_t hint = 1;

    while (src_pos < a->src_len && hint != 0) {
        size_t src_size = a->src_len - src_pos;
        size_t dst_size = a->dst_cap - dst_pos;
        rc = LZ4F_decompress(dctx, dst + dst_pos, &dst_size, src + src_pos, &src_size, NULL);
        if (LZ4F_isError(rc)) {
            a->result = 0;
            a->error_code = rc;
            LZ4F_freeDecompressionContext(dctx);
            return NULL;
        }
        src_pos += src_size;
        dst_pos += dst_size;
        if (dst_pos > a->dst_cap) {
            a->result = 0;
            a->error_code = (size_t)-1;
            LZ4F_freeDecompressionContext(dctx);
            return NULL;
        }
        hint = rc;
        if (src_size == 0 && dst_size == 0 && hint != 0)
            break;
    }

    LZ4F_freeDecompressionContext(dctx);
    if (hint != 0) {
        if (dst_pos == a->dst_cap) {
            a->result = 0;
            a->error_code = (size_t)-1;
            return NULL;
        }
        a->result = 0;
        a->error_code = (size_t)-2;
        return NULL;
    }
    a->result = dst_pos;
    a->error_code = 0;
    return NULL;
}

static void *brotli_compress_nogvl(void *arg) {
    brotli_compress_args_t *a = (brotli_compress_args_t *)arg;
    a->result = BrotliEncoderCompress(a->level, BROTLI_DEFAULT_WINDOW, BROTLI_DEFAULT_MODE,
                                      a->src_len, a->src, a->out_len, a->dst);
    return NULL;
}

typedef struct {
    ZSTD_CStream *cstream;
    ZSTD_outBuffer *output;
    ZSTD_inBuffer *input;
    size_t result;
} zstd_stream_chunk_args_t;

static void *zstd_compress_stream_chunk_nogvl(void *arg) {
    zstd_stream_chunk_args_t *a = (zstd_stream_chunk_args_t *)arg;
    a->result = ZSTD_compressStream(a->cstream, a->output, a->input);
    return NULL;
}

typedef struct {
    const char *src;
    size_t src_len;
    int level;
    ZSTD_CDict *cdict;
    char *dst;
    size_t dst_cap;
    size_t result;
    int error;
} zstd_fiber_compress_t;

typedef struct {
    ZSTD_CStream *cstream;
    ZSTD_inBuffer input;
    ZSTD_outBuffer output;
    size_t result;
} zstd_stream_chunk_fiber_t;

static void *zstd_stream_chunk_fiber_nogvl(void *arg) {
    zstd_stream_chunk_fiber_t *a = (zstd_stream_chunk_fiber_t *)arg;
    a->result = ZSTD_compressStream(a->cstream, &a->output, &a->input);
    return NULL;
}

typedef struct {
    BrotliEncoderState *enc;
    BrotliEncoderOperation op;
    size_t available_in;
    const uint8_t *next_in;
    size_t available_out;
    uint8_t *next_out;
    BROTLI_BOOL result;
} brotli_stream_chunk_fiber_t;

static void *brotli_stream_chunk_fiber_nogvl(void *arg) {
    brotli_stream_chunk_fiber_t *a = (brotli_stream_chunk_fiber_t *)arg;
    a->result = BrotliEncoderCompressStream(a->enc, a->op, &a->available_in, &a->next_in,
                                            &a->available_out, &a->next_out, NULL);
    return NULL;
}

typedef struct {
    size_t encoded_size;
    const uint8_t *encoded_buffer;
    size_t *decoded_size;
    uint8_t *decoded_buffer;
    BrotliDecoderResult result;
} brotli_decompress_args_t;

static void *brotli_decompress_nogvl(void *arg) {
    brotli_decompress_args_t *a = (brotli_decompress_args_t *)arg;
    a->result = BrotliDecoderDecompress(a->encoded_size, a->encoded_buffer, a->decoded_size,
                                        a->decoded_buffer);
    return NULL;
}

typedef struct {
    ZSTD_DStream *dstream;
    ZSTD_outBuffer *output;
    ZSTD_inBuffer *input;
    size_t result;
} zstd_decompress_stream_chunk_args_t;

static void *zstd_decompress_stream_chunk_nogvl(void *arg) {
    zstd_decompress_stream_chunk_args_t *a = (zstd_decompress_stream_chunk_args_t *)arg;
    a->result = ZSTD_decompressStream(a->dstream, a->output, a->input);
    return NULL;
}

typedef struct {
    ZSTD_DStream *dstream;
    ZSTD_outBuffer output;
    ZSTD_inBuffer input;
    size_t result;
} zstd_decompress_stream_chunk_fiber_t;

static void *zstd_decompress_stream_chunk_fiber_nogvl(void *arg) {
    zstd_decompress_stream_chunk_fiber_t *a = (zstd_decompress_stream_chunk_fiber_t *)arg;
    a->result = ZSTD_decompressStream(a->dstream, &a->output, &a->input);
    return NULL;
}

typedef struct {
    BrotliDecoderState *dec;
    size_t *available_in;
    const uint8_t **next_in;
    size_t *available_out;
    uint8_t **next_out;
    BrotliDecoderResult result;
} brotli_decompress_stream_args_t;

static void *brotli_decompress_stream_nogvl(void *arg) {
    brotli_decompress_stream_args_t *a = (brotli_decompress_stream_args_t *)arg;
    a->result = BrotliDecoderDecompressStream(a->dec, a->available_in, a->next_in, a->available_out,
                                              a->next_out, NULL);
    return NULL;
}

typedef struct {
    BrotliDecoderState *dec;
    size_t available_in;
    const uint8_t *next_in;
    size_t available_out;
    uint8_t *next_out;
    BrotliDecoderResult result;
} brotli_decompress_stream_fiber_t;

static void *brotli_decompress_stream_fiber_nogvl(void *arg) {
    brotli_decompress_stream_fiber_t *a = (brotli_decompress_stream_fiber_t *)arg;
    a->result = BrotliDecoderDecompressStream(a->dec, &a->available_in, &a->next_in,
                                              &a->available_out, &a->next_out, NULL);
    return NULL;
}

static void *zstd_fiber_compress_nogvl(void *arg) {
    zstd_fiber_compress_t *a = (zstd_fiber_compress_t *)arg;
    a->result =
        zstd_compress_cached(a->dst, a->dst_cap, a->src, a->src_len, a->level, a->cdict, &a->error);
    return NULL;
}

static VALUE compress_compress(int argc, VALUE *argv, VALUE self) {
    VALUE data, opts;
    scan_one_required_keywords(argc, argv, &data, &opts);
    StringValue(data);

    mc_opts_t parsed_opts;
    mc_parse_opts(opts, &parsed_opts);
    reject_algorithm_keyword(&parsed_opts);

    VALUE algo_sym = parsed_opts.algo;
    VALUE level_val = parsed_opts.level;
    VALUE dict_val = parsed_opts.dictionary;

    int explicit_algo = !NIL_P(algo_sym);
    compress_algo_t algo = explicit_algo ? sym_to_algo(algo_sym) : ALGO_ZSTD;
    lz4_format_t lz4_format = parse_lz4_format(&parsed_opts, algo, explicit_algo);
    int level = resolve_level(algo, level_val);

    dictionary_t *dict = NULL;
    if (!NIL_P(dict_val)) {
        if (algo == ALGO_LZ4) {
            rb_raise(eUnsupportedError, "LZ4 does not support dictionaries");
        }
        dict = opt_dictionary(dict_val);
    }

    const char *src = RSTRING_PTR(data);
    size_t slen = RSTRING_LEN(data);
    const algo_policy_t *policy = algo_policy(algo);

    switch (algo) {
    case ALGO_ZSTD: {
        size_t bound = ZSTD_compressBound(slen);

        ZSTD_CDict *cdict = NULL;
        if (dict) {
            cdict = dict_get_cdict(dict, level);
            if (!cdict)
                rb_raise(eMemError, "zstd: failed to create/get cdict");
        }

        if (slen < policy->gvl_unlock_threshold) {
            VALUE dst = rb_binary_str_buf_reserve(bound);
            int ctx_error = 0;
            size_t csize =
                zstd_compress_cached(RSTRING_PTR(dst), bound, src, slen, level, cdict, &ctx_error);
            if (ctx_error)
                rb_raise(eMemError, "zstd: failed to create context");
            if (ZSTD_isError(csize))
                rb_raise(eError, "zstd compress: %s", ZSTD_getErrorName(csize));
            rb_str_set_len(dst, (long)csize);
            RB_GC_GUARD(data);
            RB_GC_GUARD(dict_val);
            return dst;
        }

        {
            VALUE scheduler = current_fiber_scheduler();
            work_exec_mode_t mode = select_fiber_nogvl_or_direct_mode(
                scheduler, slen, policy->gvl_unlock_threshold, policy->gvl_unlock_threshold);

            if (mode == WORK_EXEC_FIBER) {
                char *out_buf = (char *)malloc(bound);
                if (!out_buf)
                    rb_raise(eMemError, "zstd: malloc failed");
                zstd_fiber_compress_t fargs = {
                    .src = src,
                    .src_len = slen,
                    .level = level,
                    .cdict = cdict,
                    .dst = out_buf,
                    .dst_cap = bound,
                    .result = 0,
                    .error = 0,
                };

                RUN_WITH_EXEC_MODE(mode, zstd_fiber_compress_nogvl, fargs);

                if (fargs.error) {
                    free(out_buf);
                    rb_raise(eMemError, "zstd: failed to create context");
                }
                if (ZSTD_isError(fargs.result)) {
                    free(out_buf);
                    rb_raise(eError, "zstd compress: %s", ZSTD_getErrorName(fargs.result));
                }

                VALUE result = rb_binary_str_new(out_buf, (long)fargs.result);
                free(out_buf);
                RB_GC_GUARD(data);
                RB_GC_GUARD(dict_val);
                return result;
            }
        }

        {
            VALUE dst = rb_binary_str_buf_reserve(bound);
            zstd_compress_args_t args = {
                .src = src,
                .src_len = slen,
                .dst = RSTRING_PTR(dst),
                .dst_cap = bound,
                .level = level,
                .cdict = cdict,
                .result = 0,
                .error = 0,
            };
            RUN_WITH_EXEC_MODE(WORK_EXEC_NOGVL, zstd_compress_nogvl, args);

            if (args.error)
                rb_raise(eMemError, "zstd: failed to create context");
            if (ZSTD_isError(args.result))
                rb_raise(eError, "zstd compress: %s", ZSTD_getErrorName(args.result));

            rb_str_set_len(dst, (long)args.result);
            RB_GC_GUARD(data);
            RB_GC_GUARD(dict_val);
            return dst;
        }
    }
    case ALGO_LZ4: {
        if (lz4_format == LZ4_FORMAT_FRAME) {
            LZ4F_preferences_t prefs;
            memset(&prefs, 0, sizeof(prefs));
            prefs.frameInfo.blockChecksumFlag = LZ4F_blockChecksumEnabled;
            prefs.frameInfo.contentChecksumFlag = LZ4F_contentChecksumEnabled;
            size_t bound = LZ4F_compressFrameBound(slen, &prefs);
            VALUE dst = rb_binary_str_buf_reserve((long)bound);
            lz4frame_compress_args_t args = {
                .src = src,
                .src_len = slen,
                .dst = RSTRING_PTR(dst),
                .dst_cap = bound,
                .result = 0,
                .error_code = 0,
            };
            {
                VALUE scheduler = current_fiber_scheduler();
                work_exec_mode_t mode = select_fiber_nogvl_or_direct_mode(
                    scheduler, slen, policy->gvl_unlock_threshold, policy->gvl_unlock_threshold);
                RUN_WITH_EXEC_MODE(mode, lz4frame_compress_nogvl, args);
            }
            if (args.error_code)
                rb_raise(eError, "lz4 frame compress failed: %s",
                         LZ4F_getErrorName(args.error_code));
            rb_str_set_len(dst, (long)args.result);
            RB_GC_GUARD(data);
            return dst;
        }
        if (slen > (size_t)INT_MAX)
            rb_raise(eError, "lz4: input too large (max 2GB)");
        int bound = LZ4_compressBound((int)slen);

        int csize;
        if (slen >= policy->gvl_unlock_threshold) {
            VALUE dst = rb_binary_str_buf_reserve(8 + (size_t)bound + 4);
            char *out = RSTRING_PTR(dst);

            write_le_u32((uint8_t *)out, (uint32_t)slen);

            lz4_compress_args_t args = {
                .src = src,
                .src_len = (int)slen,
                .dst = out + 8,
                .dst_cap = bound,
                .level = level,
            };

            VALUE scheduler = current_fiber_scheduler();
            work_exec_mode_t mode = select_fiber_nogvl_or_direct_mode(
                scheduler, slen, policy->gvl_unlock_threshold, policy->gvl_unlock_threshold);
            RUN_WITH_EXEC_MODE(mode, lz4_compress_nogvl, args);
            csize = args.result;

            if (csize <= 0)
                rb_raise(eError, "lz4 compress failed");

            write_le_u32((uint8_t *)out + 4, (uint32_t)csize);

            size_t total = 8 + (size_t)csize;
            write_le_u32((uint8_t *)out + total, 0);

            rb_str_set_len(dst, (long)(total + 4));
            RB_GC_GUARD(data);
            return dst;
        } else {
            VALUE dst = rb_binary_str_buf_reserve(8 + bound + 4);
            char *out = RSTRING_PTR(dst);

            write_le_u32((uint8_t *)out, (uint32_t)slen);

            if (level > 1) {
                csize = LZ4_compress_HC(src, out + 8, (int)slen, bound, level);
            } else {
                csize = LZ4_compress_default(src, out + 8, (int)slen, bound);
            }
            if (csize <= 0)
                rb_raise(eError, "lz4 compress failed");

            write_le_u32((uint8_t *)out + 4, (uint32_t)csize);

            size_t total = 8 + csize;
            write_le_u32((uint8_t *)out + total, 0);

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
            VALUE dst = rb_binary_str_buf_reserve(out_len);
            BrotliEncoderState *enc = BrotliEncoderCreateInstance(NULL, NULL, NULL);
            if (!enc)
                rb_raise(eMemError, "brotli: failed to create encoder");

            BrotliEncoderPreparedDictionary *pd =
                BrotliEncoderPrepareDictionary(BROTLI_SHARED_DICTIONARY_RAW, dict->size, dict->data,
                                               BROTLI_MAX_QUALITY, NULL, NULL, NULL);
            if (!pd) {
                BrotliEncoderDestroyInstance(enc);
                rb_raise(eMemError, "brotli: failed to prepare dictionary");
            }

            if (!BrotliEncoderSetParameter(enc, BROTLI_PARAM_QUALITY, level)) {
                BrotliEncoderDestroyPreparedDictionary(pd);
                BrotliEncoderDestroyInstance(enc);
                rb_raise(eError, "brotli: failed to set quality parameter");
            }
            if (!BrotliEncoderSetParameter(enc, BROTLI_PARAM_SIZE_HINT,
                                           slen > UINT32_MAX ? UINT32_MAX : (uint32_t)slen)) {
                BrotliEncoderDestroyPreparedDictionary(pd);
                BrotliEncoderDestroyInstance(enc);
                rb_raise(eError, "brotli: failed to set size hint parameter");
            }
            if (!BrotliEncoderAttachPreparedDictionary(enc, pd)) {
                BrotliEncoderDestroyPreparedDictionary(pd);
                BrotliEncoderDestroyInstance(enc);
                rb_raise(eError, "brotli: failed to attach dictionary");
            }

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
            RB_GC_GUARD(dict_val);
            return dst;
        } else if (slen >= policy->gvl_unlock_threshold) {
            VALUE dst = rb_binary_str_buf_reserve(out_len);
            size_t actual_out_len = out_len;

            brotli_compress_args_t args = {
                .level = level,
                .src_len = slen,
                .src = (const uint8_t *)src,
                .out_len = &actual_out_len,
                .dst = (uint8_t *)RSTRING_PTR(dst),
            };

            VALUE scheduler = current_fiber_scheduler();
            work_exec_mode_t mode = select_fiber_nogvl_or_direct_mode(
                scheduler, slen, policy->gvl_unlock_threshold, policy->gvl_unlock_threshold);
            RUN_WITH_EXEC_MODE(mode, brotli_compress_nogvl, args);

            if (!args.result)
                rb_raise(eError, "brotli compress failed");

            rb_str_set_len(dst, (long)actual_out_len);
            RB_GC_GUARD(data);
            return dst;
        } else {
            VALUE dst = rb_binary_str_buf_reserve(out_len);
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
    scan_one_required_keywords(argc, argv, &data, &opts);
    StringValue(data);

    mc_opts_t parsed_opts;
    mc_parse_opts(opts, &parsed_opts);
    reject_algorithm_keyword(&parsed_opts);

    VALUE algo_sym = parsed_opts.algo;
    VALUE dict_val = parsed_opts.dictionary;
    limits_config_t limits;
    parse_limits_from_parsed_opts(&parsed_opts, &limits);

    const uint8_t *src = (const uint8_t *)RSTRING_PTR(data);
    size_t slen = RSTRING_LEN(data);

    int explicit_algo = !NIL_P(algo_sym);
    compress_algo_t algo;
    if (!explicit_algo) {
        algo = detect_algo(src, slen);
    } else {
        algo = sym_to_algo(algo_sym);
    }
    lz4_format_t lz4_format = parse_lz4_format(&parsed_opts, algo, explicit_algo);

    const algo_policy_t *policy = algo_policy(algo);

    dictionary_t *dict = NULL;
    if (!NIL_P(dict_val)) {
        if (algo == ALGO_LZ4) {
            rb_raise(eUnsupportedError, "LZ4 does not support dictionaries");
        }
        dict = opt_dictionary(dict_val);
    }

    switch (algo) {
    case ALGO_ZSTD: {
        unsigned long long frame_size = ZSTD_getFrameContentSize(src, slen);
        if (frame_size == ZSTD_CONTENTSIZE_ERROR) {
            rb_raise(eDataError, "zstd: not valid compressed data");
        }

        if (frame_size != ZSTD_CONTENTSIZE_UNKNOWN) {
            if (frame_size > limits.max_output_size) {
                rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)",
                         limits.max_output_size);
            }
            enforce_output_and_ratio_limits((size_t)frame_size, slen, limits.max_output_size,
                                            limits.max_ratio_enabled, limits.max_ratio);
        }

        if (frame_size != ZSTD_CONTENTSIZE_UNKNOWN && frame_size <= limits.max_output_size) {
            size_t dsize;

            if (frame_size >= algo_policy(ALGO_ZSTD)->gvl_unlock_threshold) {
                VALUE dst = rb_binary_str_buf_reserve((size_t)frame_size);

                ZSTD_DDict *ddict = NULL;
                if (dict) {
                    ddict = dict_get_ddict(dict);
                    if (!ddict)
                        rb_raise(eMemError, "zstd: failed to create ddict");
                }

                zstd_decompress_args_t args = {
                    .src = src,
                    .src_len = slen,
                    .dst = RSTRING_PTR(dst),
                    .dst_cap = (size_t)frame_size,
                    .ddict = ddict,
                };

                VALUE scheduler = current_fiber_scheduler();
                work_exec_mode_t mode = select_fiber_nogvl_or_direct_mode(
                    scheduler, frame_size, policy->gvl_unlock_threshold,
                    policy->gvl_unlock_threshold);
                RUN_WITH_EXEC_MODE(mode, zstd_decompress_nogvl, args);

                if (args.error)
                    rb_raise(eMemError, "zstd: failed to create dctx");
                dsize = args.result;
                if (ZSTD_isError(dsize))
                    rb_raise(eDataError, "zstd decompress: %s", ZSTD_getErrorName(dsize));

                enforce_output_and_ratio_limits(dsize, slen, limits.max_output_size,
                                                limits.max_ratio_enabled, limits.max_ratio);
                rb_str_set_len(dst, (long)dsize);
                RB_GC_GUARD(data);
                RB_GC_GUARD(dict_val);
                return dst;
            } else {
                VALUE dst = rb_binary_str_buf_reserve((size_t)frame_size);

                ZSTD_DDict *ddict = NULL;
                if (dict) {
                    ddict = dict_get_ddict(dict);
                    if (!ddict)
                        rb_raise(eMemError, "zstd: failed to create ddict");
                }

                int ctx_error = 0;
                dsize = zstd_decompress_cached(RSTRING_PTR(dst), (size_t)frame_size, src, slen,
                                               ddict, &ctx_error);
                if (ctx_error)
                    rb_raise(eMemError, "zstd: failed to create dctx");

                if (ZSTD_isError(dsize))
                    rb_raise(eDataError, "zstd decompress: %s", ZSTD_getErrorName(dsize));
                enforce_output_and_ratio_limits(dsize, slen, limits.max_output_size,
                                                limits.max_ratio_enabled, limits.max_ratio);
                rb_str_set_len(dst, dsize);
                RB_GC_GUARD(data);
                RB_GC_GUARD(dict_val);
                return dst;
            }
        }

        ZSTD_DCtx *dctx = zstd_tls_get_dctx();
        if (!dctx)
            rb_raise(eMemError, "zstd: failed to create dctx");

        {
            size_t r = ZSTD_DCtx_reset(dctx, ZSTD_reset_session_and_parameters);
            if (ZSTD_isError(r))
                rb_raise(eError, "zstd dctx reset: %s", ZSTD_getErrorName(r));
        }

        if (dict) {
            ZSTD_DDict *ddict = dict_get_ddict(dict);
            if (ddict) {
                size_t r = ZSTD_DCtx_refDDict(dctx, ddict);
                if (ZSTD_isError(r)) {
                    rb_raise(eError, "zstd dict ref: %s", ZSTD_getErrorName(r));
                }
            }
        }

        size_t alloc_size = (slen > limits.max_output_size / 8) ? limits.max_output_size : slen * 8;
        if (alloc_size < 4096)
            alloc_size = limits.max_output_size < 4096 ? limits.max_output_size : 4096;
        if (alloc_size == 0)
            alloc_size = limits.max_output_size;

        VALUE dst = rb_binary_str_buf_reserve(alloc_size);
        size_t total_out = 0;

        ZSTD_inBuffer input = {src, slen, 0};
        while (input.pos < input.size) {
            if (total_out >= alloc_size) {
                if (alloc_size >= limits.max_output_size) {
                    rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)",
                             limits.max_output_size);
                }
                size_t next_cap = alloc_size * 2;
                if (next_cap > limits.max_output_size)
                    next_cap = limits.max_output_size;
                alloc_size = next_cap;
                grow_binary_str(dst, total_out, alloc_size);
            }

            size_t remaining_budget = limits.max_output_size - total_out;
            if (remaining_budget == 0) {
                rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)",
                         limits.max_output_size);
            }

            size_t out_cap = alloc_size - total_out;
            if (out_cap > remaining_budget)
                out_cap = remaining_budget;

            ZSTD_outBuffer output = {RSTRING_PTR(dst) + total_out, out_cap, 0};
            size_t ret = ZSTD_decompressStream(dctx, &output, &input);
            if (ZSTD_isError(ret)) {
                rb_raise(eDataError, "zstd decompress: %s", ZSTD_getErrorName(ret));
            }
            total_out = checked_add_size(total_out, output.pos,
                                         "decompressed output exceeds representable size");
            enforce_output_and_ratio_limits(total_out, slen, limits.max_output_size,
                                            limits.max_ratio_enabled, limits.max_ratio);
            if (ret == 0)
                break;
        }

        rb_str_set_len(dst, total_out);
        RB_GC_GUARD(data);
        RB_GC_GUARD(dict_val);
        return dst;
    }
    case ALGO_LZ4: {
        if (lz4_format == LZ4_FORMAT_FRAME || is_lz4_frame_magic(src, slen)) {
            size_t alloc_size =
                (slen > limits.max_output_size / 4) ? limits.max_output_size : slen * 4;
            if (alloc_size < 4096)
                alloc_size = limits.max_output_size < 4096 ? limits.max_output_size : 4096;
            if (alloc_size == 0)
                alloc_size = limits.max_output_size;
            VALUE dst = rb_binary_str_buf_reserve((long)alloc_size);
            while (1) {
                lz4frame_decompress_args_t args = {
                    .src = src,
                    .src_len = slen,
                    .dst = RSTRING_PTR(dst),
                    .dst_cap = alloc_size,
                    .result = 0,
                    .error_code = 0,
                };
                {
                    VALUE scheduler = current_fiber_scheduler();
                    work_exec_mode_t mode = select_fiber_nogvl_or_direct_mode(
                        scheduler, slen, policy->gvl_unlock_threshold,
                        policy->gvl_unlock_threshold);
                    RUN_WITH_EXEC_MODE(mode, lz4frame_decompress_nogvl, args);
                }
                if (args.error_code == (size_t)-1) {
                    if (alloc_size >= limits.max_output_size)
                        rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)",
                                 limits.max_output_size);
                    size_t next_cap = alloc_size * 2;
                    if (next_cap > limits.max_output_size)
                        next_cap = limits.max_output_size;
                    alloc_size = next_cap;
                    grow_binary_str(dst, 0, alloc_size);
                    continue;
                }
                if (args.error_code == (size_t)-2)
                    rb_raise(eDataError, "lz4 frame decompress failed: truncated frame");
                if (args.error_code)
                    rb_raise(eDataError, "lz4 frame decompress failed: %s",
                             LZ4F_getErrorName(args.error_code));
                enforce_output_and_ratio_limits(args.result, slen, limits.max_output_size,
                                                limits.max_ratio_enabled, limits.max_ratio);
                rb_str_set_len(dst, (long)args.result);
                RB_GC_GUARD(data);
                return dst;
            }
        }
        if (slen < 4)
            rb_raise(eDataError, "lz4: data too short");

        size_t total_orig = 0;
        size_t scan_pos = 0;
        while (scan_pos + 4 <= slen) {
            uint32_t orig_size = read_le_u32(src + scan_pos);
            if (orig_size == 0)
                break;
            if (scan_pos + 8 > slen)
                rb_raise(eDataError, "lz4: truncated block header");
            uint32_t comp_size = read_le_u32(src + scan_pos + 4);
            if (scan_pos + 8 + comp_size > slen)
                rb_raise(eDataError, "lz4: truncated block data");
            if (orig_size > 256 * 1024 * 1024)
                rb_raise(eDataError, "lz4: block too large (%u)", orig_size);
            total_orig = checked_add_size(total_orig, orig_size,
                                          "decompressed output exceeds representable size");
            if (total_orig > limits.max_output_size)
                rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)",
                         limits.max_output_size);
            scan_pos += 8 + comp_size;
        }

        enforce_output_and_ratio_limits(total_orig, slen, limits.max_output_size,
                                        limits.max_ratio_enabled, limits.max_ratio);

        VALUE result = rb_binary_str_buf_reserve(total_orig);

        lz4_decompress_all_args_t args = {
            .src = src,
            .src_len = slen,
            .dst = RSTRING_PTR(result),
            .out_offset = 0,
            .error = 0,
        };

        {
            VALUE scheduler = current_fiber_scheduler();
            work_exec_mode_t mode = select_fiber_nogvl_or_direct_mode(
                scheduler, total_orig, algo_policy(ALGO_LZ4)->gvl_unlock_threshold,
                algo_policy(ALGO_LZ4)->gvl_unlock_threshold);
            RUN_WITH_EXEC_MODE(mode, lz4_decompress_all_nogvl, args);
        }

        if (args.error)
            rb_raise(eDataError, "%s", args.err_msg);

        enforce_output_and_ratio_limits(args.out_offset, slen, limits.max_output_size,
                                        limits.max_ratio_enabled, limits.max_ratio);
        rb_str_set_len(result, args.out_offset);
        RB_GC_GUARD(data);
        return result;
    }
    case ALGO_BROTLI: {
        size_t alloc_size = (slen > limits.max_output_size / 4) ? limits.max_output_size : slen * 4;
        if (alloc_size < 1024)
            alloc_size = limits.max_output_size < 1024 ? limits.max_output_size : 1024;
        if (alloc_size == 0)
            alloc_size = limits.max_output_size;

        BrotliDecoderState *dec = BrotliDecoderCreateInstance(NULL, NULL, NULL);
        if (!dec)
            rb_raise(eMemError, "brotli: failed to create decoder");

        if (dict) {
            BrotliDecoderAttachDictionary(dec, BROTLI_SHARED_DICTIONARY_RAW, dict->size,
                                          dict->data);
        }

        VALUE dst = rb_binary_str_buf_reserve(alloc_size);
        size_t total_out = 0;

        size_t available_in = slen;
        const uint8_t *next_in = src;

        VALUE scheduler = current_fiber_scheduler();

        BrotliDecoderResult res = BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT;
        while (res == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
            size_t remaining_budget = limits.max_output_size - total_out;
            if (remaining_budget == 0) {
                BrotliDecoderDestroyInstance(dec);
                rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)",
                         limits.max_output_size);
            }

            size_t available_out = alloc_size - total_out;
            if (available_out > remaining_budget)
                available_out = remaining_budget;
            uint8_t *next_out = (uint8_t *)RSTRING_PTR(dst) + total_out;

            if (select_fiber_or_direct_mode(scheduler, available_in,
                                            policy->fiber_stream_threshold) == WORK_EXEC_FIBER) {
                brotli_decompress_stream_fiber_t sargs = {
                    .dec = dec,
                    .available_in = available_in,
                    .next_in = next_in,
                    .available_out = available_out,
                    .next_out = next_out,
                    .result = BROTLI_DECODER_RESULT_ERROR,
                };
                RUN_VIA_FIBER_WORKER(brotli_decompress_stream_fiber_nogvl, sargs);
                available_in = sargs.available_in;
                next_in = sargs.next_in;
                available_out = sargs.available_out;
                next_out = sargs.next_out;
                res = sargs.result;
            } else {
                res = BrotliDecoderDecompressStream(dec, &available_in, &next_in, &available_out,
                                                    &next_out, NULL);
            }

            total_out = next_out - (uint8_t *)RSTRING_PTR(dst);
            enforce_output_and_ratio_limits(total_out, slen, limits.max_output_size,
                                            limits.max_ratio_enabled, limits.max_ratio);

            if (res == BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT) {
                if (alloc_size >= limits.max_output_size) {
                    BrotliDecoderDestroyInstance(dec);
                    rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)",
                             limits.max_output_size);
                }
                size_t next_cap = alloc_size * 2;
                if (next_cap > limits.max_output_size)
                    next_cap = limits.max_output_size;
                alloc_size = next_cap;
                grow_binary_str(dst, total_out, alloc_size);
            }
        }

        BrotliDecoderDestroyInstance(dec);

        if (res != BROTLI_DECODER_RESULT_SUCCESS) {
            rb_raise(eDataError, "brotli decompress failed");
        }
        rb_str_set_len(dst, total_out);
        RB_GC_GUARD(data);
        RB_GC_GUARD(dict_val);
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
            crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
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

static uint32_t crc32_compute(const uint8_t *restrict data, size_t len, uint32_t crc) {
    crc = ~crc;

    while (len >= 8) {
        const uint32_t val0 = crc ^ ((uint32_t)data[0] | ((uint32_t)data[1] << 8) |
                                     ((uint32_t)data[2] << 16) | ((uint32_t)data[3] << 24));
        const uint32_t val1 = (uint32_t)data[4] | ((uint32_t)data[5] << 8) |
                              ((uint32_t)data[6] << 16) | ((uint32_t)data[7] << 24);

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
    (void)self;
    VALUE data, prev;
    rb_scan_args(argc, argv, "11", &data, &prev);
    StringValue(data);

    const uint8_t *restrict src = (const uint8_t *)RSTRING_PTR(data);
    size_t len = (size_t)RSTRING_LEN(data);
    const uint32_t adler = NIL_P(prev) ? 1u : NUM2UINT(prev);

    uint32_t s1 = adler & 0xFFFFu;
    uint32_t s2 = (adler >> 16) & 0xFFFFu;
    enum { ADLER_BASE = 65521, ADLER_NMAX = 5552 };

    while (len > 0) {
        size_t chunk = len > ADLER_NMAX ? (size_t)ADLER_NMAX : len;
        len -= chunk;

        while (chunk >= 8) {
            s1 += src[0];
            s2 += s1;
            s1 += src[1];
            s2 += s1;
            s1 += src[2];
            s2 += s1;
            s1 += src[3];
            s2 += s1;
            s1 += src[4];
            s2 += s1;
            s1 += src[5];
            s2 += s1;
            s1 += src[6];
            s2 += s1;
            s1 += src[7];
            s2 += s1;
            src += 8;
            chunk -= 8;
        }
        while (chunk--) {
            s1 += *src++;
            s2 += s1;
        }
        s1 %= ADLER_BASE;
        s2 %= ADLER_BASE;
    }

    return UINT2NUM((s2 << 16) | s1);
}

static VALUE compress_algorithms(VALUE self) {
    VALUE ary = rb_ary_new_capa(3);
    rb_ary_push(ary, sym_cache.zstd);
    rb_ary_push(ary, sym_cache.lz4);
    rb_ary_push(ary, sym_cache.brotli);
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

_Static_assert(LZ4_RING_BUFFER_TOTAL == 2 * LZ4_RING_BUFFER_SIZE,
               "ring buffer total must be exactly twice the window size");

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
    if (!d)
        return 0;

    size_t s = sizeof(deflater_t);
    switch (d->algo) {
    case ALGO_ZSTD:
        if (d->ctx.zstd)
            s += ZSTD_sizeof_CStream(d->ctx.zstd);
        break;
    case ALGO_BROTLI:
        break;
    case ALGO_LZ4:
        if (d->lz4_ring.buf)
            s += LZ4_RING_BUFFER_TOTAL;
        break;
    }
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
    scan_zero_required_keywords(argc, argv, &opts);

    mc_opts_t parsed_opts;
    mc_parse_opts(opts, &parsed_opts);
    reject_algorithm_keyword(&parsed_opts);

    deflater_t *d;
    TypedData_Get_Struct(self, deflater_t, &deflater_type, d);

    VALUE algo_sym = parsed_opts.algo;
    VALUE level_val = parsed_opts.level;
    VALUE dict_val = parsed_opts.dictionary;

    d->algo = NIL_P(algo_sym) ? ALGO_ZSTD : sym_to_algo(algo_sym);
    d->level = resolve_level(d->algo, level_val);
    d->closed = 0;
    d->finished = 0;

    dictionary_t *dict = NULL;
    if (!NIL_P(dict_val)) {
        if (d->algo == ALGO_LZ4) {
            rb_raise(eUnsupportedError, "LZ4 does not support dictionaries");
        }
        dict = opt_dictionary(dict_val);
        dictionary_ivar_set(self, dict_val);
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
        if (!BrotliEncoderSetParameter(d->ctx.brotli, BROTLI_PARAM_QUALITY, d->level)) {
            BrotliEncoderDestroyInstance(d->ctx.brotli);
            d->ctx.brotli = NULL;
            rb_raise(eError, "brotli: failed to set quality parameter");
        }
        if (dict) {
            BrotliEncoderPreparedDictionary *pd =
                BrotliEncoderPrepareDictionary(BROTLI_SHARED_DICTIONARY_RAW, dict->size, dict->data,
                                               BROTLI_MAX_QUALITY, NULL, NULL, NULL);
            if (!pd) {
                BrotliEncoderDestroyInstance(d->ctx.brotli);
                d->ctx.brotli = NULL;
                rb_raise(eMemError, "brotli: failed to prepare dictionary");
            }
            if (!BrotliEncoderAttachPreparedDictionary(d->ctx.brotli, pd)) {
                BrotliEncoderDestroyPreparedDictionary(pd);
                BrotliEncoderDestroyInstance(d->ctx.brotli);
                d->ctx.brotli = NULL;
                rb_raise(eError, "brotli: failed to attach dictionary");
            }
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

    write_le_u32((uint8_t *)out, (uint32_t)src_size);

    /* Keep blocks independently decodable. Switching to LZ4_*_continue would
     * require a coordinated format/decoder change that preserves dictionaries
     * across blocks.
     */
    int csize;
    if (d->level > 1) {
        csize = LZ4_compress_HC(block_start, out + 8, src_size, bound, d->level);
    } else {
        csize = LZ4_compress_default(block_start, out + 8, src_size, bound);
    }
    if (csize <= 0)
        rb_raise(eError, "lz4 stream compress block failed");

    write_le_u32((uint8_t *)out + 4, (uint32_t)csize);

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
    const algo_policy_t *policy = algo_policy(d->algo);
    if (slen == 0)
        return rb_binary_str_new("", 0);

    switch (d->algo) {
    case ALGO_ZSTD: {
        ZSTD_inBuffer input = {src, slen, 0};
        size_t out_cap = ZSTD_CStreamOutSize();
        size_t result_cap = out_cap > slen ? out_cap : slen;
        VALUE result = rb_binary_str_buf_reserve(result_cap);
        size_t result_len = 0;
        VALUE scheduler = current_fiber_scheduler();

        while (input.pos < input.size) {
            if (result_len + out_cap > result_cap) {
                result_cap = result_cap * 2;
                grow_binary_str(result, result_len, result_cap);
            }

            ZSTD_outBuffer output = {RSTRING_PTR(result) + result_len, out_cap, 0};

            {
                work_exec_mode_t mode = select_fiber_nogvl_or_direct_mode(
                    scheduler, input.size - input.pos, policy->fiber_stream_threshold,
                    policy->gvl_unlock_threshold);

                if (mode == WORK_EXEC_FIBER) {
                    zstd_stream_chunk_fiber_t fargs = {
                        .cstream = d->ctx.zstd,
                        .input = input,
                        .output = output,
                        .result = 0,
                    };
                    RUN_WITH_EXEC_MODE(mode, zstd_stream_chunk_fiber_nogvl, fargs);
                    input.pos = fargs.input.pos;
                    output.pos = fargs.output.pos;

                    if (ZSTD_isError(fargs.result))
                        rb_raise(eError, "zstd compress stream: %s",
                                 ZSTD_getErrorName(fargs.result));
                } else if (mode == WORK_EXEC_NOGVL) {
                    zstd_stream_chunk_args_t args = {
                        .cstream = d->ctx.zstd,
                        .output = &output,
                        .input = &input,
                        .result = 0,
                    };
                    RUN_WITH_EXEC_MODE(mode, zstd_compress_stream_chunk_nogvl, args);
                    if (ZSTD_isError(args.result))
                        rb_raise(eError, "zstd compress stream: %s",
                                 ZSTD_getErrorName(args.result));
                } else {
                    size_t ret = ZSTD_compressStream(d->ctx.zstd, &output, &input);
                    if (ZSTD_isError(ret))
                        rb_raise(eError, "zstd compress stream: %s", ZSTD_getErrorName(ret));
                }
            }
            result_len += output.pos;
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
        VALUE result = rb_binary_str_buf_reserve(result_cap);
        size_t result_len = 0;
        VALUE scheduler = current_fiber_scheduler();
        int use_fiber = (scheduler != Qnil);
        size_t fiber_counter = 0;

        while (available_in > 0 || BrotliEncoderHasMoreOutput(d->ctx.brotli)) {
            size_t available_out = 0;
            uint8_t *next_out = NULL;
            BROTLI_BOOL ok;

            if (use_fiber &&
                select_fiber_or_direct_mode(scheduler, available_in,
                                            policy->fiber_stream_threshold) == WORK_EXEC_FIBER) {
                brotli_stream_chunk_fiber_t fargs = {
                    .enc = d->ctx.brotli,
                    .op = BROTLI_OPERATION_PROCESS,
                    .available_in = available_in,
                    .next_in = next_in,
                    .available_out = available_out,
                    .next_out = next_out,
                    .result = BROTLI_FALSE,
                };
                RUN_VIA_FIBER_WORKER(brotli_stream_chunk_fiber_nogvl, fargs);
                available_in = fargs.available_in;
                next_in = fargs.next_in;
                available_out = fargs.available_out;
                next_out = fargs.next_out;
                ok = fargs.result;
            } else {
                ok = BrotliEncoderCompressStream(d->ctx.brotli, BROTLI_OPERATION_PROCESS,
                                                 &available_in, &next_in, &available_out, &next_out,
                                                 NULL);
            }
            if (!ok)
                rb_raise(eError, "brotli compress stream failed");

            const uint8_t *out_data;
            size_t out_size = 0;
            out_data = BrotliEncoderTakeOutput(d->ctx.brotli, &out_size);
            if (out_size > 0) {
                if (result_len + out_size > result_cap) {
                    result_cap = (result_len + out_size) * 2;
                    grow_binary_str(result, result_len, result_cap);
                }

                memcpy(RSTRING_PTR(result) + result_len, out_data, out_size);
                result_len += out_size;
                if (use_fiber) {
                    int did_yield = 0;
                    fiber_counter = fiber_maybe_yield(fiber_counter, out_size,
                                                      policy->fiber_yield_chunk, &did_yield);
                    (void)did_yield;
                }
            }
        }
        rb_str_set_len(result, result_len);
        RB_GC_GUARD(chunk);
        return result;
    }
    case ALGO_LZ4: {
        VALUE result = rb_binary_str_buf_reserve(0);
        size_t result_len = 0;
        size_t result_cap = 0;
        int use_fiber = has_fiber_scheduler();
        size_t fiber_counter = 0;

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
                        grow_binary_str(result, result_len, result_cap);
                    }
                    memcpy(RSTRING_PTR(result) + result_len, RSTRING_PTR(block), blen);
                    result_len += blen;
                }
                if (use_fiber) {
                    int did_yield = 0;
                    fiber_counter = fiber_maybe_yield(fiber_counter, LZ4_RING_BUFFER_SIZE,
                                                      policy->fiber_yield_chunk, &did_yield);
                    (void)did_yield;
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
        VALUE result = rb_binary_str_buf_reserve(result_cap);
        size_t result_len = 0;
        size_t ret;

        do {
            if (result_len + out_cap > result_cap) {
                result_cap *= 2;
                grow_binary_str(result, result_len, result_cap);
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
        VALUE result = rb_binary_str_buf_reserve(result_cap);
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
                    grow_binary_str(result, result_len, result_cap);
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
        VALUE result = rb_binary_str_buf_reserve(result_cap);
        size_t result_len = 0;
        size_t ret;

        do {
            if (result_len + out_cap > result_cap) {
                result_cap *= 2;
                grow_binary_str(result, result_len, result_cap);
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
        VALUE result = rb_binary_str_buf_reserve(result_cap);
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
                    grow_binary_str(result, result_len, result_cap);
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
        VALUE result = rb_binary_str_buf_reserve(result_cap);
        size_t result_len = 0;

        if (d->lz4_ring.pending > 0) {
            VALUE block = lz4_compress_ring_block(d);
            size_t blen = RSTRING_LEN(block);
            if (blen > 0) {
                if (blen + 4 > result_cap) {
                    result_cap = blen + 4;
                    grow_binary_str(result, result_len, result_cap);
                }

                memcpy(RSTRING_PTR(result), RSTRING_PTR(block), blen);
                result_len = blen;
            }
        }

        if (result_len + 4 > result_cap) {
            result_cap = result_len + 4;
            grow_binary_str(result, result_len, result_cap);
        }

        char *out = RSTRING_PTR(result) + result_len;
        write_le_u32((uint8_t *)out, 0);
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

    VALUE dict_val = dictionary_ivar_get(self);
    dictionary_t *dict = NULL;
    if (!NIL_P(dict_val)) {
        TypedData_Get_Struct(dict_val, dictionary_t, &dictionary_type, dict);
    }

    switch (d->algo) {
    case ALGO_ZSTD:
        if (d->ctx.zstd) {
            ZSTD_CCtx_reset(d->ctx.zstd, ZSTD_reset_session_only);
            ZSTD_CCtx_setParameter(d->ctx.zstd, ZSTD_c_compressionLevel, d->level);
            if (dict) {
                size_t r = ZSTD_CCtx_loadDictionary(d->ctx.zstd, dict->data, dict->size);
                if (ZSTD_isError(r))
                    rb_raise(eError, "zstd dict reload on reset: %s", ZSTD_getErrorName(r));
            }
        }
        break;
    case ALGO_BROTLI:
        if (d->ctx.brotli) {
            BrotliEncoderDestroyInstance(d->ctx.brotli);
            d->ctx.brotli = BrotliEncoderCreateInstance(NULL, NULL, NULL);
            if (!d->ctx.brotli)
                rb_raise(eMemError, "brotli: failed to recreate encoder");
            if (!BrotliEncoderSetParameter(d->ctx.brotli, BROTLI_PARAM_QUALITY, d->level))
                rb_raise(eError, "brotli: failed to set quality on reset");
            if (dict) {
                BrotliEncoderPreparedDictionary *pd = BrotliEncoderPrepareDictionary(
                    BROTLI_SHARED_DICTIONARY_RAW, dict->size, dict->data, BROTLI_MAX_QUALITY, NULL,
                    NULL, NULL);
                if (!pd)
                    rb_raise(eMemError, "brotli: failed to prepare dictionary on reset");
                if (!BrotliEncoderAttachPreparedDictionary(d->ctx.brotli, pd)) {
                    BrotliEncoderDestroyPreparedDictionary(pd);
                    rb_raise(eError, "brotli: failed to reattach dictionary on reset");
                }
                BrotliEncoderDestroyPreparedDictionary(pd);
            }
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
    size_t max_output_size;
    size_t total_output;
    size_t total_input;
    int max_ratio_enabled;
    unsigned long long max_ratio;

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
    if (!inf)
        return 0;

    size_t s = sizeof(inflater_t);
    switch (inf->algo) {
    case ALGO_ZSTD:
        if (inf->ctx.zstd)
            s += ZSTD_sizeof_DStream(inf->ctx.zstd);
        break;
    case ALGO_BROTLI:
        break;
    case ALGO_LZ4:
        s += inf->lz4_buf.cap;
        break;
    }
    return s;
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
    scan_zero_required_keywords(argc, argv, &opts);

    mc_opts_t parsed_opts;
    mc_parse_opts(opts, &parsed_opts);
    reject_algorithm_keyword(&parsed_opts);

    inflater_t *inf;
    TypedData_Get_Struct(self, inflater_t, &inflater_type, inf);

    VALUE algo_sym = parsed_opts.algo;
    VALUE dict_val = parsed_opts.dictionary;
    limits_config_t limits;
    parse_limits_from_parsed_opts(&parsed_opts, &limits);

    inf->algo = NIL_P(algo_sym) ? ALGO_ZSTD : sym_to_algo(algo_sym);
    inf->closed = 0;
    inf->finished = 0;
    inf->max_output_size = limits.max_output_size;
    inf->total_output = 0;
    inf->total_input = 0;
    inf->max_ratio_enabled = limits.max_ratio_enabled;
    inf->max_ratio = limits.max_ratio;

    dictionary_t *dict = NULL;
    if (!NIL_P(dict_val)) {
        if (inf->algo == ALGO_LZ4) {
            rb_raise(eUnsupportedError, "LZ4 does not support dictionaries");
        }
        dict = opt_dictionary(dict_val);
        dictionary_ivar_set(self, dict_val);
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
    const algo_policy_t *policy = algo_policy(inf->algo);
    if (slen == 0)
        return rb_binary_str_new("", 0);

    size_t input_accounted_before = inf->total_input;

    switch (inf->algo) {
    case ALGO_ZSTD: {
        ZSTD_inBuffer input = {src, slen, 0};
        size_t out_cap = ZSTD_DStreamOutSize();
        size_t result_cap = out_cap > slen * 2 ? out_cap : slen * 2;
        size_t remaining_total_budget =
            inf->max_output_size > inf->total_output ? inf->max_output_size - inf->total_output : 0;
        if (remaining_total_budget == 0)
            rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)",
                     inf->max_output_size);
        if (result_cap > remaining_total_budget)
            result_cap = remaining_total_budget;
        VALUE result = rb_binary_str_buf_reserve(result_cap);
        size_t result_len = 0;
        VALUE scheduler = current_fiber_scheduler();

        while (input.pos < input.size) {
            size_t remaining_budget = inf->max_output_size - inf->total_output - result_len;
            if (remaining_budget == 0)
                rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)",
                         inf->max_output_size);

            if (result_len + out_cap > result_cap) {
                size_t next_cap = result_cap * 2;
                if (next_cap > inf->max_output_size - inf->total_output)
                    next_cap = inf->max_output_size - inf->total_output;
                result_cap = next_cap;
                rb_str_resize(result, result_cap);
            }

            size_t current_out_cap = out_cap;
            if (current_out_cap > remaining_budget)
                current_out_cap = remaining_budget;

            ZSTD_outBuffer output = {RSTRING_PTR(result) + result_len, current_out_cap, 0};
            size_t ret;

            if (select_fiber_or_direct_mode(scheduler, input.size - input.pos,
                                            policy->fiber_stream_threshold) == WORK_EXEC_FIBER) {
                zstd_decompress_stream_chunk_fiber_t args = {
                    .dstream = inf->ctx.zstd,
                    .output = output,
                    .input = input,
                    .result = 0,
                };
                RUN_VIA_FIBER_WORKER(zstd_decompress_stream_chunk_fiber_nogvl, args);
                output.pos = args.output.pos;
                input.pos = args.input.pos;
                ret = args.result;
            } else {
                ret = ZSTD_decompressStream(inf->ctx.zstd, &output, &input);
            }

            if (ZSTD_isError(ret))
                rb_raise(eDataError, "zstd decompress stream: %s", ZSTD_getErrorName(ret));
            result_len = checked_add_size(result_len, output.pos,
                                          "decompressed output exceeds representable size");
            size_t total_output = checked_add_size(
                inf->total_output, result_len, "decompressed output exceeds representable size");
            size_t total_input = checked_add_size(input_accounted_before, input.pos,
                                                  "compressed input exceeds representable size");
            enforce_output_and_ratio_limits(total_output, total_input, inf->max_output_size,
                                            inf->max_ratio_enabled, inf->max_ratio);
            if (ret == 0)
                break;
        }
        inf->total_input = checked_add_size(input_accounted_before, input.pos,
                                            "compressed input exceeds representable size");
        inf->total_output = checked_add_size(inf->total_output, result_len,
                                             "decompressed output exceeds representable size");
        rb_str_set_len(result, result_len);
        RB_GC_GUARD(chunk);
        return result;
    }
    case ALGO_BROTLI: {
        size_t available_in = slen;
        const uint8_t *next_in = (const uint8_t *)src;
        size_t remaining_total_budget =
            inf->max_output_size > inf->total_output ? inf->max_output_size - inf->total_output : 0;
        if (remaining_total_budget == 0)
            rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)",
                     inf->max_output_size);
        size_t result_cap = slen * 2;
        if (result_cap < 1024)
            result_cap = 1024;
        if (result_cap > remaining_total_budget)
            result_cap = remaining_total_budget;
        VALUE result = rb_binary_str_buf_reserve(result_cap);
        size_t result_len = 0;
        VALUE scheduler = current_fiber_scheduler();

        while (available_in > 0 || BrotliDecoderHasMoreOutput(inf->ctx.brotli)) {
            size_t available_out = 0;
            uint8_t *next_out = NULL;
            BrotliDecoderResult res;

            if (select_fiber_or_direct_mode(scheduler, available_in,
                                            policy->fiber_stream_threshold) == WORK_EXEC_FIBER) {
                brotli_decompress_stream_fiber_t sargs = {
                    .dec = inf->ctx.brotli,
                    .available_in = available_in,
                    .next_in = next_in,
                    .available_out = available_out,
                    .next_out = next_out,
                    .result = BROTLI_DECODER_RESULT_ERROR,
                };
                RUN_VIA_FIBER_WORKER(brotli_decompress_stream_fiber_nogvl, sargs);
                available_in = sargs.available_in;
                next_in = sargs.next_in;
                available_out = sargs.available_out;
                next_out = sargs.next_out;
                res = sargs.result;
            } else {
                res = BrotliDecoderDecompressStream(inf->ctx.brotli, &available_in, &next_in,
                                                    &available_out, &next_out, NULL);
            }
            if (res == BROTLI_DECODER_RESULT_ERROR)
                rb_raise(eDataError, "brotli decompress stream: %s",
                         BrotliDecoderErrorString(BrotliDecoderGetErrorCode(inf->ctx.brotli)));
            const uint8_t *out_data;
            size_t out_size = 0;
            out_data = BrotliDecoderTakeOutput(inf->ctx.brotli, &out_size);
            if (out_size > 0) {
                size_t total_output = checked_add_size(
                    inf->total_output,
                    checked_add_size(result_len, out_size,
                                     "decompressed output exceeds representable size"),
                    "decompressed output exceeds representable size");
                size_t total_input =
                    checked_add_size(input_accounted_before, slen - available_in,
                                     "compressed input exceeds representable size");
                enforce_output_and_ratio_limits(total_output, total_input, inf->max_output_size,
                                                inf->max_ratio_enabled, inf->max_ratio);

                if (result_len + out_size > result_cap) {
                    result_cap = result_len + out_size;
                    rb_str_resize(result, result_cap);
                }

                memcpy(RSTRING_PTR(result) + result_len, out_data, out_size);
                result_len += out_size;
            }
            if (res == BROTLI_DECODER_RESULT_SUCCESS)
                break;
            if (res == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT && available_in == 0)
                break;
        }
        inf->total_input = checked_add_size(input_accounted_before, slen - available_in,
                                            "compressed input exceeds representable size");
        inf->total_output = checked_add_size(inf->total_output, result_len,
                                             "decompressed output exceeds representable size");
        rb_str_set_len(result, result_len);
        RB_GC_GUARD(chunk);
        return result;
    }
    case ALGO_LZ4: {
        size_t data_len = inf->lz4_buf.len - inf->lz4_buf.offset;
        size_t needed =
            checked_add_size(data_len, slen, "lz4 stream input buffer exceeds representable size");

        if (needed > inf->lz4_buf.cap) {
            size_t new_cap = needed > SIZE_MAX / 2 ? needed : needed * 2;
            if (inf->lz4_buf.offset > 0) {
                char *new_buf = ALLOC_N(char, new_cap);
                if (data_len > 0)
                    memcpy(new_buf, inf->lz4_buf.buf + inf->lz4_buf.offset, data_len);
                xfree(inf->lz4_buf.buf);
                inf->lz4_buf.buf = new_buf;
                inf->lz4_buf.offset = 0;
                inf->lz4_buf.len = data_len;
                inf->lz4_buf.cap = new_cap;
            } else {
                REALLOC_N(inf->lz4_buf.buf, char, new_cap);
                inf->lz4_buf.cap = new_cap;
            }
        } else if (inf->lz4_buf.offset > inf->lz4_buf.cap / 2) {
            if (data_len > 0)
                memmove(inf->lz4_buf.buf, inf->lz4_buf.buf + inf->lz4_buf.offset, data_len);
            inf->lz4_buf.offset = 0;
            inf->lz4_buf.len = data_len;
        }

        memcpy(inf->lz4_buf.buf + inf->lz4_buf.len, src, slen);
        inf->lz4_buf.len += slen;

        size_t remaining_total_budget =
            inf->max_output_size > inf->total_output ? inf->max_output_size - inf->total_output : 0;
        if (remaining_total_budget == 0)
            rb_raise(eDataError, "decompressed output exceeds limit (%zu bytes)",
                     inf->max_output_size);
        size_t result_cap = slen * 4;
        if (result_cap < 256)
            result_cap = 256;
        if (result_cap > remaining_total_budget)
            result_cap = remaining_total_budget;
        VALUE result = rb_binary_str_buf_new(result_cap);
        size_t result_len = 0;
        int use_fiber = has_fiber_scheduler();
        size_t fiber_counter = 0;

        size_t pos = inf->lz4_buf.offset;
        while (pos + 4 <= inf->lz4_buf.len) {
            const uint8_t *p = (const uint8_t *)(inf->lz4_buf.buf + pos);
            uint32_t orig_size = read_le_u32(p);
            if (orig_size == 0) {
                inf->finished = 1;
                pos += 4;
                break;
            }
            if (pos + 8 > inf->lz4_buf.len)
                break;
            uint32_t comp_size = read_le_u32(p + 4);
            if (pos + 8 + comp_size > inf->lz4_buf.len)
                break;
            if (orig_size > 64 * 1024 * 1024)
                rb_raise(eDataError, "lz4 stream: block too large (%u)", orig_size);

            size_t total_output =
                checked_add_size(inf->total_output,
                                 checked_add_size(result_len, orig_size,
                                                  "decompressed output exceeds representable size"),
                                 "decompressed output exceeds representable size");
            size_t total_input = checked_add_size(
                input_accounted_before, (pos + 8 + (size_t)comp_size) - inf->lz4_buf.offset,
                "compressed input exceeds representable size");
            enforce_output_and_ratio_limits(total_output, total_input, inf->max_output_size,
                                            inf->max_ratio_enabled, inf->max_ratio);

            if (result_len + orig_size > result_cap) {
                result_cap = result_len + orig_size;
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
                fiber_counter = fiber_maybe_yield(fiber_counter, (size_t)dsize,
                                                  policy->fiber_yield_chunk, &did_yield);
                (void)did_yield;
            }
        }

        inf->total_input = checked_add_size(input_accounted_before, pos - inf->lz4_buf.offset,
                                            "compressed input exceeds representable size");
        inf->lz4_buf.offset = pos;
        inf->total_output = checked_add_size(inf->total_output, result_len,
                                             "decompressed output exceeds representable size");
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

    VALUE dict_val = dictionary_ivar_get(self);
    dictionary_t *dict = NULL;
    if (!NIL_P(dict_val)) {
        TypedData_Get_Struct(dict_val, dictionary_t, &dictionary_type, dict);
    }

    switch (inf->algo) {
    case ALGO_ZSTD:
        if (inf->ctx.zstd) {
            ZSTD_DCtx_reset(inf->ctx.zstd, ZSTD_reset_session_only);
            if (dict) {
                size_t r = ZSTD_DCtx_loadDictionary(inf->ctx.zstd, dict->data, dict->size);
                if (ZSTD_isError(r))
                    rb_raise(eError, "zstd dict reload on reset: %s", ZSTD_getErrorName(r));
            }
        }
        break;
    case ALGO_BROTLI:
        if (inf->ctx.brotli) {
            BrotliDecoderDestroyInstance(inf->ctx.brotli);
            inf->ctx.brotli = BrotliDecoderCreateInstance(NULL, NULL, NULL);
            if (!inf->ctx.brotli)
                rb_raise(eMemError, "brotli: failed to recreate decoder");
            if (dict) {
                BrotliDecoderAttachDictionary(inf->ctx.brotli, BROTLI_SHARED_DICTIONARY_RAW,
                                              dict->size, dict->data);
            }
        }
        break;
    case ALGO_LZ4:
        inf->lz4_buf.len = 0;
        inf->lz4_buf.offset = 0;
        break;
    }
    inf->closed = 0;
    inf->finished = 0;
    inf->total_output = 0;
    inf->total_input = 0;
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
    scan_one_required_keywords(argc, argv, &raw, &opts);
    StringValue(raw);

    mc_opts_t parsed_opts;
    mc_parse_opts(opts, &parsed_opts);
    reject_algorithm_keyword(&parsed_opts);

    dictionary_t *d;
    TypedData_Get_Struct(self, dictionary_t, &dictionary_type, d);

    VALUE algo_sym = parsed_opts.algo;
    d->algo = NIL_P(algo_sym) ? ALGO_ZSTD : sym_to_algo(algo_sym);

    if (d->algo == ALGO_LZ4)
        rb_raise(eUnsupportedError, "LZ4 does not support dictionaries");

    d->size = RSTRING_LEN(raw);
    d->data = ALLOC_N(uint8_t, d->size);
    memcpy(d->data, RSTRING_PTR(raw), d->size);

    return self;
}

static VALUE train_dictionary_internal(VALUE samples, VALUE size_val, compress_algo_t algo) {
    Check_Type(samples, T_ARRAY);

    if (algo == ALGO_BROTLI) {
        rb_raise(eUnsupportedError, "Brotli dictionary training is not supported via this API. "
                                    "Create a raw dictionary using "
                                    "MultiCompress::Dictionary.new(data, algo: :brotli)");
    }

    size_t dict_capacity = NIL_P(size_val) ? 112640 /* 110 KiB, zstd default */
                                           : NUM2SIZET(size_val);
    if (dict_capacity < 256)
        rb_raise(rb_eArgError, "dictionary size must be at least 256 bytes");

    long num_samples = RARRAY_LEN(samples);
    if (num_samples < 1)
        rb_raise(rb_eArgError, "need at least 1 sample for training");

    size_t total_size = 0;
    for (long i = 0; i < num_samples; i++) {
        VALUE s = rb_ary_entry(samples, i);
        StringValue(s);
        size_t slen = RSTRING_LEN(s);
        if (slen < 8)
            rb_raise(rb_eArgError, "sample %ld is too small (%zu bytes), minimum is 8 bytes", i,
                     slen);
        total_size += slen;
    }

    uint8_t *dict_buf = ALLOC_N(uint8_t, dict_capacity);
    char *concat = ALLOC_N(char, total_size);
    size_t *sizes = ALLOC_N(size_t, (size_t)num_samples);

    size_t offset = 0;
    for (long i = 0; i < num_samples; i++) {
        VALUE s = rb_ary_entry(samples, i);
        StringValue(s);
        size_t slen = RSTRING_LEN(s);
        memcpy(concat + offset, RSTRING_PTR(s), slen);
        sizes[i] = slen;
        offset += slen;
        RB_GC_GUARD(s);
    }

    size_t dict_size =
        ZDICT_trainFromBuffer(dict_buf, dict_capacity, concat, sizes, (unsigned)num_samples);

    xfree(concat);
    xfree(sizes);

    if (ZDICT_isError(dict_size)) {
        const char *err = ZDICT_getErrorName(dict_size);
        xfree(dict_buf);
        rb_raise(eError,
                 "dictionary training failed: %s "
                 "(tip: provide more samples; total sample bytes should be "
                 "~100x the dictionary size)",
                 err);
    }

    VALUE dict_obj = dict_alloc(cDictionary);
    dictionary_t *d;
    TypedData_Get_Struct(dict_obj, dictionary_t, &dictionary_type, d);
    memset(d, 0, sizeof(*d));
    d->algo = algo;
    d->data = dict_buf;
    d->size = dict_size;
    return dict_obj;
}

static VALUE zstd_train_dictionary(int argc, VALUE *argv, VALUE self) {
    VALUE samples, opts;
    scan_one_required_keywords(argc, argv, &samples, &opts);
    mc_opts_t parsed_opts;
    mc_parse_opts(opts, &parsed_opts);
    reject_algorithm_keyword(&parsed_opts);
    return train_dictionary_internal(samples, parsed_opts.size, ALGO_ZSTD);
}

static VALUE brotli_train_dictionary(int argc, VALUE *argv, VALUE self) {
    VALUE samples, opts;
    scan_one_required_keywords(argc, argv, &samples, &opts);
    mc_opts_t parsed_opts;
    mc_parse_opts(opts, &parsed_opts);
    reject_algorithm_keyword(&parsed_opts);

    return train_dictionary_internal(samples, parsed_opts.size, ALGO_BROTLI);
}

static VALUE dict_load(int argc, VALUE *argv, VALUE self) {
    VALUE path, opts;
    scan_one_required_keywords(argc, argv, &path, &opts);
    StringValue(path);
    raise_if_path_has_null_byte(path);

    mc_opts_t parsed_opts;
    mc_parse_opts(opts, &parsed_opts);
    reject_algorithm_keyword(&parsed_opts);

    VALUE algo_sym = parsed_opts.algo;
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
    if ((unsigned long long)file_size > DICT_FILE_MAX_SIZE) {
        fclose(f);
        rb_raise(eDataError, "dictionary file too large (%ld bytes, max=%d)", file_size,
                 (int)DICT_FILE_MAX_SIZE);
    }

    uint8_t *buf = ALLOC_N(uint8_t, file_size);
    size_t read_bytes = fread(buf, 1, file_size, f);
    fclose(f);

    if ((long)read_bytes != file_size) {
        xfree(buf);
        rb_raise(eDataError, "failed to read dictionary: %s", cpath);
    }

    VALUE dict_obj = dict_alloc(cDictionary);
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
    return algo_to_sym(d->algo);
}

static VALUE dict_size(VALUE self) {
    dictionary_t *d;
    TypedData_Get_Struct(self, dictionary_t, &dictionary_type, d);
    return SIZET2NUM(d->size);
}

void Init_multi_compress(void) {
    binary_encoding = rb_ascii8bit_encoding();
    init_id_cache();
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
    rb_define_singleton_method(mZstd, "train_dictionary", zstd_train_dictionary, -1);
    rb_define_singleton_method(mBrotli, "train_dictionary", brotli_train_dictionary, -1);
}
