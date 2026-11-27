// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef _FILE_OFFSET_BITS
#define _FILE_OFFSET_BITS 64
#endif

#include "CZlib.h"
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <zlib.h>
#include <zstd.h>

#ifdef __linux__
#include <dlfcn.h>
#include <pthread.h>
#endif

// libarchive v3 ABI types and constants declared directly because Apple iPhoneOS SDK
// ships libarchive.2.tbd without public <archive.h> headers.
struct archive;
struct archive_entry;

typedef int64_t la_int64_t;
typedef ptrdiff_t la_ssize_t;
typedef la_ssize_t (*la_read_cb)(struct archive *, void *client_data, const void **buffer);
typedef int (*la_open_cb)(struct archive *, void *client_data);
typedef int (*la_close_cb)(struct archive *, void *client_data);

enum {
    CZ_ARCHIVE_EOF = 1,
    CZ_ARCHIVE_OK = 0,
    CZ_ARCHIVE_RETRY = -10,
    CZ_ARCHIVE_WARN = -20,
    CZ_ARCHIVE_FAILED = -25,
    CZ_ARCHIVE_FATAL = -30
};

#define CZ_AE_IFMT 0170000U
#define CZ_AE_IFREG 0100000U
#define CZ_AE_IFDIR 0040000U

#ifdef __APPLE__

extern struct archive *archive_read_new(void);
extern int archive_read_support_filter_all(struct archive *);
extern int archive_read_support_format_all(struct archive *);
extern int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
extern int archive_read_open(struct archive *, void *client_data, la_open_cb, la_read_cb, la_close_cb);
extern int archive_read_next_header(struct archive *, struct archive_entry **);
extern int archive_read_data_block(struct archive *, const void **buff, size_t *size, la_int64_t *offset);
extern int archive_read_data_skip(struct archive *);
extern int archive_read_has_encrypted_entries(struct archive *);
extern la_int64_t archive_position_compressed(struct archive *);
extern const char *archive_error_string(struct archive *);
extern int archive_read_free(struct archive *);
extern const char *archive_entry_pathname_utf8(struct archive_entry *);
extern const char *archive_entry_pathname(struct archive_entry *);
extern mode_t archive_entry_filetype(struct archive_entry *);
extern int archive_entry_is_encrypted(struct archive_entry *);

static int cz_load_libarchive(char *err_buf, size_t err_cap) {
    (void)err_buf;
    (void)err_cap;
    return 0;
}

#define sym_archive_read_new archive_read_new
#define sym_archive_read_support_filter_all archive_read_support_filter_all
#define sym_archive_read_support_format_all archive_read_support_format_all
#define sym_archive_read_open_filename archive_read_open_filename
#define sym_archive_read_open archive_read_open
#define sym_archive_read_next_header archive_read_next_header
#define sym_archive_read_data_block archive_read_data_block
#define sym_archive_read_data_skip archive_read_data_skip
#define sym_archive_read_has_encrypted_entries archive_read_has_encrypted_entries
#define sym_archive_position_compressed archive_position_compressed
#define sym_archive_error_string archive_error_string
#define sym_archive_read_free archive_read_free
#define sym_archive_entry_pathname_utf8 archive_entry_pathname_utf8
#define sym_archive_entry_pathname archive_entry_pathname
#define sym_archive_entry_filetype archive_entry_filetype
#define sym_archive_entry_is_encrypted archive_entry_is_encrypted

#else

static struct archive *(*sym_archive_read_new)(void);
static int (*sym_archive_read_support_filter_all)(struct archive *);
static int (*sym_archive_read_support_format_all)(struct archive *);
static int (*sym_archive_read_open_filename)(struct archive *, const char *filename, size_t block_size);
static int (*sym_archive_read_open)(struct archive *, void *client_data, la_open_cb, la_read_cb, la_close_cb);
static int (*sym_archive_read_next_header)(struct archive *, struct archive_entry **);
static int (*sym_archive_read_data_block)(struct archive *, const void **buff, size_t *size, la_int64_t *offset);
static int (*sym_archive_read_data_skip)(struct archive *);
static int (*sym_archive_read_has_encrypted_entries)(struct archive *);
static la_int64_t (*sym_archive_position_compressed)(struct archive *);
static const char *(*sym_archive_error_string)(struct archive *);
static int (*sym_archive_read_free)(struct archive *);
static const char *(*sym_archive_entry_pathname_utf8)(struct archive_entry *);
static const char *(*sym_archive_entry_pathname)(struct archive_entry *);
static mode_t (*sym_archive_entry_filetype)(struct archive_entry *);
static int (*sym_archive_entry_is_encrypted)(struct archive_entry *);

static pthread_once_t g_libarchive_once = PTHREAD_ONCE_INIT;
static int g_libarchive_ready = 0;

static void cz_init_libarchive_once(void) {
    void *h = dlopen("libarchive.so.13", RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        h = dlopen("libarchive.so", RTLD_NOW | RTLD_LOCAL);
    }
    if (!h) {
        return;
    }

    sym_archive_read_new = (struct archive *(*)(void))dlsym(h, "archive_read_new");
    sym_archive_read_support_filter_all = (int (*)(struct archive *))dlsym(h, "archive_read_support_filter_all");
    sym_archive_read_support_format_all = (int (*)(struct archive *))dlsym(h, "archive_read_support_format_all");
    sym_archive_read_open_filename = (int (*)(struct archive *, const char *, size_t))dlsym(h, "archive_read_open_filename");
    sym_archive_read_open = (int (*)(struct archive *, void *, la_open_cb, la_read_cb, la_close_cb))dlsym(h, "archive_read_open");
    sym_archive_read_next_header = (int (*)(struct archive *, struct archive_entry **))dlsym(h, "archive_read_next_header");
    sym_archive_read_data_block = (int (*)(struct archive *, const void **, size_t *, la_int64_t *))dlsym(h, "archive_read_data_block");
    sym_archive_read_data_skip = (int (*)(struct archive *))dlsym(h, "archive_read_data_skip");
    sym_archive_read_has_encrypted_entries = (int (*)(struct archive *))dlsym(h, "archive_read_has_encrypted_entries");
    sym_archive_position_compressed = (la_int64_t (*)(struct archive *))dlsym(h, "archive_position_compressed");
    sym_archive_error_string = (const char *(*)(struct archive *))dlsym(h, "archive_error_string");
    sym_archive_read_free = (int (*)(struct archive *))dlsym(h, "archive_read_free");
    sym_archive_entry_pathname_utf8 = (const char *(*)(struct archive_entry *))dlsym(h, "archive_entry_pathname_utf8");
    sym_archive_entry_pathname = (const char *(*)(struct archive_entry *))dlsym(h, "archive_entry_pathname");
    sym_archive_entry_filetype = (mode_t (*)(struct archive_entry *))dlsym(h, "archive_entry_filetype");
    sym_archive_entry_is_encrypted = (int (*)(struct archive_entry *))dlsym(h, "archive_entry_is_encrypted");

    if (sym_archive_read_new &&
        sym_archive_read_support_filter_all &&
        sym_archive_read_support_format_all &&
        sym_archive_read_open_filename &&
        sym_archive_read_open &&
        sym_archive_read_next_header &&
        sym_archive_read_data_block &&
        sym_archive_read_data_skip &&
        sym_archive_read_has_encrypted_entries &&
        sym_archive_position_compressed &&
        sym_archive_error_string &&
        sym_archive_read_free &&
        sym_archive_entry_pathname_utf8 &&
        sym_archive_entry_pathname &&
        sym_archive_entry_filetype &&
        sym_archive_entry_is_encrypted) {
        g_libarchive_ready = 1;
    }
}

static int cz_load_libarchive(char *err_buf, size_t err_cap) {
    pthread_once(&g_libarchive_once, cz_init_libarchive_once);
    if (!g_libarchive_ready) {
        if (err_buf && err_cap > 0) {
            snprintf(err_buf, err_cap, "libarchive shared library is unavailable");
        }
        return -1;
    }
    return 0;
}

#endif

static void set_err(char *err_buf, size_t err_cap, const char *msg) {
    if (err_buf && err_cap > 0) {
        snprintf(err_buf, err_cap, "%s", msg ? msg : "unknown error");
    }
}

static int contains_ci(const char *haystack, const char *needle) {
    if (!haystack || !needle) return 0;
    size_t nlen = strlen(needle);
    if (nlen == 0) return 1;
    for (const char *p = haystack; *p; ++p) {
        size_t i = 0;
        while (i < nlen && p[i] != '\0') {
            char a = p[i];
            char b = needle[i];
            if (a >= 'A' && a <= 'Z') a += ('a' - 'A');
            if (b >= 'A' && b <= 'Z') b += ('a' - 'A');
            if (a != b) break;
            ++i;
        }
        if (i == nlen) return 1;
    }
    return 0;
}

static int is_encrypted_error(const char *msg) {
    return contains_ci(msg, "passphrase") ||
           contains_ci(msg, "encrypted") ||
           contains_ci(msg, "password");
}

static int mkdir_p(const char *path) {
    if (!path || path[0] == '\0') return 0;
    size_t len = strlen(path);
    char *tmp = (char *)malloc(len + 1);
    if (!tmp) return -1;
    memcpy(tmp, path, len + 1);

    for (char *p = tmp + 1; *p != '\0'; ++p) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
                free(tmp);
                return -1;
            }
            *p = '/';
        }
    }
    if (mkdir(tmp, 0755) != 0 && errno != EEXIST) {
        free(tmp);
        return -1;
    }
    free(tmp);
    return 0;
}

static int ensure_parent_dir(const char *file_path) {
    const char *slash = strrchr(file_path, '/');
    if (!slash || slash == file_path) return 0;
    size_t dlen = (size_t)(slash - file_path);
    char *dir = (char *)malloc(dlen + 1);
    if (!dir) return -1;
    memcpy(dir, file_path, dlen);
    dir[dlen] = '\0';
    int rc = mkdir_p(dir);
    free(dir);
    return rc;
}

typedef struct {
    FILE *fp;
    ZSTD_DCtx *dctx;
    uint8_t in_buf[65536];
    uint8_t out_buf[65536];
    size_t in_pos;
    size_t in_size;
    int eof;
    uint64_t bytes_read;
} zstd_stream_ctx_t;

static int is_zstd_magic(const uint8_t hdr[4]) {
    if (hdr[0] == 0x28 && hdr[1] == 0xB5 && hdr[2] == 0x2F && hdr[3] == 0xFD) {
        return 1;
    }
    if ((hdr[0] & 0xF0) == 0x50 && hdr[1] == 0x2A && hdr[2] == 0x4D && hdr[3] == 0x18) {
        return 1;
    }
    return 0;
}

static la_ssize_t zstd_archive_read_cb(struct archive *a, void *client_data, const void **buff) {
    (void)a;
    zstd_stream_ctx_t *ctx = (zstd_stream_ctx_t *)client_data;
    for (;;) {
        if (ctx->in_pos == ctx->in_size && !ctx->eof) {
            size_t n = fread(ctx->in_buf, 1, sizeof(ctx->in_buf), ctx->fp);
            ctx->in_pos = 0;
            ctx->in_size = n;
            ctx->bytes_read += (uint64_t)n;
            if (n == 0) {
                if (ferror(ctx->fp)) return -1;
                ctx->eof = 1;
            }
        }

        if (ctx->eof && ctx->in_pos == ctx->in_size) {
            return 0;
        }

        ZSTD_inBuffer input = { ctx->in_buf, ctx->in_size, ctx->in_pos };
        ZSTD_outBuffer output = { ctx->out_buf, sizeof(ctx->out_buf), 0 };
        size_t rc = ZSTD_decompressStream(ctx->dctx, &output, &input);
        ctx->in_pos = input.pos;
        if (ZSTD_isError(rc)) {
            return -1;
        }
        if (output.pos > 0) {
            *buff = ctx->out_buf;
            return (la_ssize_t)output.pos;
        }
    }
}

static int zstd_archive_close_cb(struct archive *a, void *client_data) {
    (void)a;
    zstd_stream_ctx_t *ctx = (zstd_stream_ctx_t *)client_data;
    if (ctx) {
        if (ctx->dctx) ZSTD_freeDCtx(ctx->dctx);
        if (ctx->fp) fclose(ctx->fp);
        free(ctx);
    }
    return CZ_ARCHIVE_OK;
}

int czlib_extract_archive(
    const char *archive_path,
    const char *dest_dir,
    czlib_path_transform_fn transform_cb,
    czlib_progress_fn progress_cb,
    void *userdata,
    char *err_buf,
    size_t err_cap
) {
    if (!archive_path || !dest_dir) {
        set_err(err_buf, err_cap, "Missing archive or destination path");
        return CZLIB_ARCHIVE_ERR_OPEN;
    }

    if (cz_load_libarchive(err_buf, err_cap) != 0) {
        return CZLIB_ARCHIVE_ERR_OPEN;
    }

    struct stat st;
    if (stat(archive_path, &st) != 0) {
        set_err(err_buf, err_cap, strerror(errno));
        return CZLIB_ARCHIVE_ERR_OPEN;
    }
    uint64_t total_size = st.st_size > 0 ? (uint64_t)st.st_size : 1ULL;

    if (mkdir_p(dest_dir) != 0) {
        set_err(err_buf, err_cap, strerror(errno));
        return CZLIB_ARCHIVE_ERR_IO;
    }

    int use_zstd_wrapper = 0;
    {
        FILE *probe = fopen(archive_path, "rb");
        if (!probe) {
            set_err(err_buf, err_cap, strerror(errno));
            return CZLIB_ARCHIVE_ERR_OPEN;
        }
        uint8_t magic[4] = {0};
        if (fread(magic, 1, 4, probe) == 4 && is_zstd_magic(magic)) {
            use_zstd_wrapper = 1;
        }
        fclose(probe);
    }

    struct archive *a = sym_archive_read_new();
    if (!a) {
        set_err(err_buf, err_cap, "archive_read_new failed");
        return CZLIB_ARCHIVE_ERR_OPEN;
    }

    sym_archive_read_support_filter_all(a);
    sym_archive_read_support_format_all(a);

    zstd_stream_ctx_t *zctx = NULL;
    int open_rc;
    if (use_zstd_wrapper) {
        zctx = (zstd_stream_ctx_t *)calloc(1, sizeof(zstd_stream_ctx_t));
        if (!zctx) {
            sym_archive_read_free(a);
            set_err(err_buf, err_cap, "Out of memory");
            return CZLIB_ARCHIVE_ERR_IO;
        }
        zctx->fp = fopen(archive_path, "rb");
        zctx->dctx = ZSTD_createDCtx();
        if (!zctx->fp || !zctx->dctx) {
            zstd_archive_close_cb(a, zctx);
            sym_archive_read_free(a);
            set_err(err_buf, err_cap, "Failed to initialize zstd archive reader");
            return CZLIB_ARCHIVE_ERR_OPEN;
        }
        open_rc = sym_archive_read_open(a, zctx, NULL, zstd_archive_read_cb, zstd_archive_close_cb);
    } else {
        open_rc = sym_archive_read_open_filename(a, archive_path, 65536);
    }

    if (open_rc != CZ_ARCHIVE_OK) {
        const char *msg = sym_archive_error_string(a);
        set_err(err_buf, err_cap, msg ? msg : "Failed to open archive");
        int code = is_encrypted_error(msg) ? CZLIB_ARCHIVE_ERR_ENCRYPTED : CZLIB_ARCHIVE_ERR_FORMAT;
        sym_archive_read_free(a);
        return code;
    }

    size_t dest_len = strlen(dest_dir);
    int strip_trailing_slash = (dest_len > 1 && dest_dir[dest_len - 1] == '/') ? 1 : 0;
    size_t clean_dest_len = dest_len - (size_t)strip_trailing_slash;
    char rel_buf[4096];
    size_t entry_idx = 0;
    uint64_t last_reported_bytes = 0;
    int final_status = CZLIB_ARCHIVE_OK;

    for (;;) {
        struct archive_entry *entry = NULL;
        int r = sym_archive_read_next_header(a, &entry);
        if (r == CZ_ARCHIVE_EOF) {
            break;
        }
        if (r < CZ_ARCHIVE_WARN) {
            const char *msg = sym_archive_error_string(a);
            set_err(err_buf, err_cap, msg ? msg : "Corrupt or unsupported archive header");
            final_status = is_encrypted_error(msg) ? CZLIB_ARCHIVE_ERR_ENCRYPTED : CZLIB_ARCHIVE_ERR_FORMAT;
            break;
        }

        if (sym_archive_entry_is_encrypted(entry) != 0 || sym_archive_read_has_encrypted_entries(a) > 0) {
            set_err(err_buf, err_cap, "Password-protected archives are not supported");
            final_status = CZLIB_ARCHIVE_ERR_ENCRYPTED;
            break;
        }

        mode_t ftype = sym_archive_entry_filetype(entry);
        mode_t kind = ftype & CZ_AE_IFMT;
        int is_dir = (kind == CZ_AE_IFDIR) ? 1 : 0;
        int is_reg = (kind == CZ_AE_IFREG || kind == 0) ? 1 : 0;
        if (!is_dir && !is_reg) {
            sym_archive_read_data_skip(a);
            continue;
        }

        const char *raw_name = sym_archive_entry_pathname_utf8(entry);
        if (!raw_name) {
            raw_name = sym_archive_entry_pathname(entry);
        }
        if (!raw_name) {
            sym_archive_read_data_skip(a);
            continue;
        }

        if (transform_cb) {
            int trc = transform_cb(raw_name, is_dir, rel_buf, sizeof(rel_buf), userdata);
            if (trc == 1) {
                sym_archive_read_data_skip(a);
                continue;
            }
            if (trc == -1) {
                set_err(err_buf, err_cap, raw_name);
                final_status = CZLIB_ARCHIVE_ERR_UNSAFE_PATH;
                break;
            }
            if (trc != 0) {
                set_err(err_buf, err_cap, raw_name);
                final_status = CZLIB_ARCHIVE_ERR_FORMAT;
                break;
            }
        } else {
            snprintf(rel_buf, sizeof(rel_buf), "%s", raw_name);
        }

        if (rel_buf[0] == '\0') {
            sym_archive_read_data_skip(a);
            continue;
        }

        size_t rlen = strlen(rel_buf);
        char *full_path = (char *)malloc(clean_dest_len + 1 + rlen + 1);
        if (!full_path) {
            set_err(err_buf, err_cap, "Out of memory");
            final_status = CZLIB_ARCHIVE_ERR_IO;
            break;
        }
        memcpy(full_path, dest_dir, clean_dest_len);
        full_path[clean_dest_len] = '/';
        memcpy(full_path + clean_dest_len + 1, rel_buf, rlen + 1);

        if (is_dir) {
            int mrc = mkdir_p(full_path);
            free(full_path);
            if (mrc != 0) {
                set_err(err_buf, err_cap, strerror(errno));
                final_status = CZLIB_ARCHIVE_ERR_IO;
                break;
            }
        } else {
            if (ensure_parent_dir(full_path) != 0) {
                set_err(err_buf, err_cap, strerror(errno));
                free(full_path);
                final_status = CZLIB_ARCHIVE_ERR_IO;
                break;
            }
            FILE *out = fopen(full_path, "wb");
            free(full_path);
            if (!out) {
                set_err(err_buf, err_cap, strerror(errno));
                final_status = CZLIB_ARCHIVE_ERR_IO;
                break;
            }

            la_int64_t written_end = 0;
            for (;;) {
                const void *block = NULL;
                size_t bsize = 0;
                la_int64_t offset = 0;
                int dr = sym_archive_read_data_block(a, &block, &bsize, &offset);
                if (dr == CZ_ARCHIVE_EOF) {
                    break;
                }
                if (dr < CZ_ARCHIVE_WARN) {
                    const char *msg = sym_archive_error_string(a);
                    set_err(err_buf, err_cap, msg ? msg : "Failed to decompress archive entry");
                    final_status = is_encrypted_error(msg) ? CZLIB_ARCHIVE_ERR_ENCRYPTED : CZLIB_ARCHIVE_ERR_FORMAT;
                    break;
                }
                if (bsize > 0 && block) {
                    if (offset != written_end) {
                        if (fseeko(out, (off_t)offset, SEEK_SET) != 0) {
                            set_err(err_buf, err_cap, strerror(errno));
                            final_status = CZLIB_ARCHIVE_ERR_IO;
                            break;
                        }
                    }
                    if (fwrite(block, 1, bsize, out) != bsize) {
                        set_err(err_buf, err_cap, strerror(errno));
                        final_status = CZLIB_ARCHIVE_ERR_IO;
                        break;
                    }
                    written_end = offset + (la_int64_t)bsize;
                }
            }
            if (fclose(out) != 0 && final_status == CZLIB_ARCHIVE_OK) {
                set_err(err_buf, err_cap, strerror(errno));
                final_status = CZLIB_ARCHIVE_ERR_IO;
            }
            if (final_status != CZLIB_ARCHIVE_OK) {
                break;
            }
        }

        if (progress_cb) {
            uint64_t pos = use_zstd_wrapper && zctx
                ? zctx->bytes_read
                : (uint64_t)sym_archive_position_compressed(a);
            if (entry_idx % 16 == 0 || pos - last_reported_bytes >= 512U * 1024U) {
                double frac = (double)pos / (double)total_size;
                if (frac < 0.0) frac = 0.0;
                if (frac > 0.99) frac = 0.99;
                progress_cb(frac, rel_buf, userdata);
                last_reported_bytes = pos;
            }
        }
        entry_idx++;
    }

    if (final_status == CZLIB_ARCHIVE_OK && progress_cb) {
        progress_cb(1.0, rel_buf, userdata);
    }

    sym_archive_read_free(a);
    return final_status;
}

int czlib_zstd_compress(
    const uint8_t *in_buf,
    size_t in_len,
    int level,
    uint8_t **out_buf,
    size_t *out_len
) {
    if (!out_buf || !out_len) return -1;
    *out_buf = NULL;
    *out_len = 0;

    size_t bound = ZSTD_compressBound(in_len);
    uint8_t *buf = (uint8_t *)malloc(bound > 0 ? bound : 1);
    if (!buf) return -1;

    size_t res = ZSTD_compress(buf, bound, in_buf, in_len, level);
    if (ZSTD_isError(res)) {
        free(buf);
        return -1;
    }
    *out_buf = buf;
    *out_len = res;
    return 0;
}

int czlib_zstd_decompress(
    const uint8_t *in_buf,
    size_t in_len,
    uint8_t **out_buf,
    size_t *out_len
) {
    if (!out_buf || !out_len) return -1;
    *out_buf = NULL;
    *out_len = 0;

    ZSTD_DStream *dstream = ZSTD_createDStream();
    if (!dstream) return -1;

    size_t init_rc = ZSTD_initDStream(dstream);
    if (ZSTD_isError(init_rc)) {
        ZSTD_freeDStream(dstream);
        return -1;
    }

    size_t cap = in_len < 1024 ? 4096 : in_len * 4;
    if (cap < 4096) cap = 4096;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) {
        ZSTD_freeDStream(dstream);
        return -1;
    }

    ZSTD_inBuffer input = { in_buf, in_len, 0 };
    size_t total = 0;

    while (input.pos < input.size) {
        if (total == cap) {
            if (cap > SIZE_MAX / 2) {
                free(buf);
                ZSTD_freeDStream(dstream);
                return -1;
            }
            size_t new_cap = cap * 2;
            uint8_t *grown = (uint8_t *)realloc(buf, new_cap);
            if (!grown) {
                free(buf);
                ZSTD_freeDStream(dstream);
                return -1;
            }
            buf = grown;
            cap = new_cap;
        }
        ZSTD_outBuffer output = { buf + total, cap - total, 0 };
        size_t rc = ZSTD_decompressStream(dstream, &output, &input);
        if (ZSTD_isError(rc)) {
            free(buf);
            ZSTD_freeDStream(dstream);
            return -1;
        }
        total += output.pos;
    }

    ZSTD_freeDStream(dstream);
    *out_buf = buf;
    *out_len = total;
    return 0;
}

int czlib_zstd_stream_slice(
    const char *in_path,
    uint64_t offset,
    uint64_t comp_size,
    const char *out_path
) {
    if (!in_path || !out_path) return -1;
    FILE *in = fopen(in_path, "rb");
    if (!in) return -1;
    if (fseeko(in, (off_t)offset, SEEK_SET) != 0) {
        fclose(in);
        return -1;
    }
    if (ensure_parent_dir(out_path) != 0) {
        fclose(in);
        return -1;
    }
    FILE *out = fopen(out_path, "wb");
    if (!out) {
        fclose(in);
        return -1;
    }

    ZSTD_DCtx *dctx = ZSTD_createDCtx();
    if (!dctx) {
        fclose(out);
        fclose(in);
        return -1;
    }

    uint8_t in_buf[65536];
    uint8_t out_buf[65536];
    uint64_t remaining = comp_size;
    int status = 0;

    while (remaining > 0) {
        size_t want = remaining > sizeof(in_buf) ? sizeof(in_buf) : (size_t)remaining;
        size_t got = fread(in_buf, 1, want, in);
        if (got == 0) {
            status = -1;
            break;
        }
        remaining -= (uint64_t)got;

        ZSTD_inBuffer input = { in_buf, got, 0 };
        while (input.pos < input.size) {
            ZSTD_outBuffer output = { out_buf, sizeof(out_buf), 0 };
            size_t rc = ZSTD_decompressStream(dctx, &output, &input);
            if (ZSTD_isError(rc)) {
                status = -1;
                break;
            }
            if (output.pos > 0 && fwrite(out_buf, 1, output.pos, out) != output.pos) {
                status = -1;
                break;
            }
        }
        if (status != 0) break;
    }

    ZSTD_freeDCtx(dctx);
    if (fclose(out) != 0) status = -1;
    fclose(in);
    return status;
}

int czlib_inflate_stream_slice(
    const char *in_path,
    uint64_t offset,
    uint64_t comp_size,
    int raw_deflate,
    const char *out_path
) {
    if (!in_path || !out_path) return -1;
    FILE *in = fopen(in_path, "rb");
    if (!in) return -1;
    if (fseeko(in, (off_t)offset, SEEK_SET) != 0) {
        fclose(in);
        return -1;
    }
    if (ensure_parent_dir(out_path) != 0) {
        fclose(in);
        return -1;
    }
    FILE *out = fopen(out_path, "wb");
    if (!out) {
        fclose(in);
        return -1;
    }

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2(&strm, raw_deflate ? -MAX_WBITS : MAX_WBITS) != Z_OK) {
        fclose(out);
        fclose(in);
        return -1;
    }

    uint8_t in_buf[65536];
    uint8_t out_buf[65536];
    uint64_t remaining = comp_size;
    int status = 0;

    for (;;) {
        if (strm.avail_in == 0 && remaining > 0) {
            size_t want = remaining > sizeof(in_buf) ? sizeof(in_buf) : (size_t)remaining;
            size_t got = fread(in_buf, 1, want, in);
            if (got == 0) {
                status = -1;
                break;
            }
            remaining -= (uint64_t)got;
            strm.next_in = in_buf;
            strm.avail_in = (uInt)got;
        }

        strm.next_out = out_buf;
        strm.avail_out = (uInt)sizeof(out_buf);
        int rc = inflate(&strm, Z_NO_FLUSH);
        size_t produced = sizeof(out_buf) - strm.avail_out;
        if (produced > 0 && fwrite(out_buf, 1, produced, out) != produced) {
            status = -1;
            break;
        }
        if (rc == Z_STREAM_END) {
            break;
        }
        if (rc != Z_OK) {
            status = -1;
            break;
        }
        if (strm.avail_in == 0 && remaining == 0 && strm.avail_out > 0) {
            status = -1;
            break;
        }
    }

    inflateEnd(&strm);
    if (fclose(out) != 0) status = -1;
    fclose(in);
    return status;
}
