// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef CZLIB_H
#define CZLIB_H

#include <stddef.h>
#include <stdint.h>

enum {
    CZLIB_ARCHIVE_OK = 0,
    CZLIB_ARCHIVE_ERR_OPEN = -1,
    CZLIB_ARCHIVE_ERR_FORMAT = -2,
    CZLIB_ARCHIVE_ERR_UNSAFE_PATH = -3,
    CZLIB_ARCHIVE_ERR_ENCRYPTED = -4,
    CZLIB_ARCHIVE_ERR_IO = -5
};

// Returns 0 to extract into out_rel, 1 to skip entry, -1 on unsafe path, -2 on other error.
typedef int (*czlib_path_transform_fn)(
    const char *raw_path,
    int is_dir,
    char *out_rel,
    size_t out_cap,
    void *ctx
);

typedef void (*czlib_progress_fn)(
    double fraction,
    const char *rel_path,
    void *ctx
);

// Inflates zlib-wrapped (raw=0) or raw deflate (raw=1) bytes.
// Allocates *out_buf with malloc; caller must free with czlib_free.
// Returns 0 on success, non-zero zlib error code on failure.
int czlib_inflate(
    const uint8_t *in_buf,
    size_t in_len,
    int raw_deflate,
    uint8_t **out_buf,
    size_t *out_len
);

// Compresses bytes using raw deflate (raw=1) or zlib (raw=0).
// Allocates *out_buf with malloc; caller must free with czlib_free.
// Returns 0 on success, non-zero zlib error code on failure.
int czlib_deflate(
    const uint8_t *in_buf,
    size_t in_len,
    int raw_deflate,
    int level,
    uint8_t **out_buf,
    size_t *out_len
);

// Inflates a gzip stream (windowBits = 16 + MAX_WBITS).
int czlib_gunzip(
    const uint8_t *in_buf,
    size_t in_len,
    uint8_t **out_buf,
    size_t *out_len
);

// Compresses and decompresses single Zstandard buffers.
// Allocates *out_buf with malloc; caller must free with czlib_free.
int czlib_zstd_compress(
    const uint8_t *in_buf,
    size_t in_len,
    int level,
    uint8_t **out_buf,
    size_t *out_len
);

int czlib_zstd_decompress(
    const uint8_t *in_buf,
    size_t in_len,
    uint8_t **out_buf,
    size_t *out_len
);

// Streams a Zstandard-compressed slice from in_path[offset..offset+comp_size) directly to out_path.
int czlib_zstd_stream_slice(
    const char *in_path,
    uint64_t offset,
    uint64_t comp_size,
    const char *out_path
);

// Streams a deflate-compressed slice from in_path[offset..offset+comp_size) directly to out_path.
int czlib_inflate_stream_slice(
    const char *in_path,
    uint64_t offset,
    uint64_t comp_size,
    int raw_deflate,
    const char *out_path
);

// Streams extraction of 7z, RAR/RAR5, ZIP/ZIP64, TAR, TAR.GZ, TAR.BZ2, TAR.XZ, TAR.ZST, CAB, ISO, and XAR.
int czlib_extract_archive(
    const char *archive_path,
    const char *dest_dir,
    czlib_path_transform_fn transform_cb,
    czlib_progress_fn progress_cb,
    void *userdata,
    char *err_buf,
    size_t err_cap
);

uint32_t czlib_crc32(uint32_t crc, const uint8_t *buf, size_t len);
void czlib_free(void *ptr);

#endif
