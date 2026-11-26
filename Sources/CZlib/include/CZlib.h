// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef CZLIB_H
#define CZLIB_H

#include <stddef.h>
#include <stdint.h>

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

uint32_t czlib_crc32(uint32_t crc, const uint8_t *buf, size_t len);
void czlib_free(void *ptr);

#endif
