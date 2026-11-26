// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#include "CZlib.h"
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static int run_inflate(const uint8_t *in_buf, size_t in_len, int window_bits, uint8_t **out_buf, size_t *out_len) {
    if (!out_buf || !out_len) {
        return Z_STREAM_ERROR;
    }
    *out_buf = NULL;
    *out_len = 0;

    if (in_len == 0) {
        *out_buf = (uint8_t *)malloc(1);
        return *out_buf ? Z_OK : Z_MEM_ERROR;
    }

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.next_in = (Bytef *)(uintptr_t)in_buf;
    strm.avail_in = (uInt)in_len;

    int ret = inflateInit2(&strm, window_bits);
    if (ret != Z_OK) {
        return ret;
    }

    size_t cap = in_len < 1024 ? 4096 : in_len * 4;
    if (cap < 4096) cap = 4096;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) {
        inflateEnd(&strm);
        return Z_MEM_ERROR;
    }

    size_t total = 0;
    for (;;) {
        if (total == cap) {
            if (cap > SIZE_MAX / 2) {
                free(buf);
                inflateEnd(&strm);
                return Z_MEM_ERROR;
            }
            size_t new_cap = cap * 2;
            uint8_t *grown = (uint8_t *)realloc(buf, new_cap);
            if (!grown) {
                free(buf);
                inflateEnd(&strm);
                return Z_MEM_ERROR;
            }
            buf = grown;
            cap = new_cap;
        }

        strm.next_out = buf + total;
        strm.avail_out = (uInt)(cap - total);
        ret = inflate(&strm, Z_NO_FLUSH);
        total = cap - strm.avail_out;

        if (ret == Z_STREAM_END) {
            break;
        }
        if (ret != Z_OK) {
            free(buf);
            inflateEnd(&strm);
            return ret;
        }
        if (strm.avail_in == 0 && strm.avail_out > 0) {
            // Truncated input stream
            free(buf);
            inflateEnd(&strm);
            return Z_DATA_ERROR;
        }
    }

    inflateEnd(&strm);
    *out_buf = buf;
    *out_len = total;
    return Z_OK;
}

int czlib_inflate(const uint8_t *in_buf, size_t in_len, int raw_deflate, uint8_t **out_buf, size_t *out_len) {
    return run_inflate(in_buf, in_len, raw_deflate ? -MAX_WBITS : MAX_WBITS, out_buf, out_len);
}

int czlib_gunzip(const uint8_t *in_buf, size_t in_len, uint8_t **out_buf, size_t *out_len) {
    return run_inflate(in_buf, in_len, 16 + MAX_WBITS, out_buf, out_len);
}

int czlib_deflate(const uint8_t *in_buf, size_t in_len, int raw_deflate, int level, uint8_t **out_buf, size_t *out_len) {
    if (!out_buf || !out_len) {
        return Z_STREAM_ERROR;
    }
    *out_buf = NULL;
    *out_len = 0;

    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    int window_bits = raw_deflate ? -MAX_WBITS : MAX_WBITS;
    int ret = deflateInit2(&strm, level, Z_DEFLATED, window_bits, 8, Z_DEFAULT_STRATEGY);
    if (ret != Z_OK) {
        return ret;
    }

    uLong bound = deflateBound(&strm, (uLong)in_len);
    uint8_t *buf = (uint8_t *)malloc((size_t)bound + 16);
    if (!buf) {
        deflateEnd(&strm);
        return Z_MEM_ERROR;
    }

    strm.next_in = (Bytef *)(uintptr_t)in_buf;
    strm.avail_in = (uInt)in_len;
    strm.next_out = buf;
    strm.avail_out = (uInt)(bound + 16);

    ret = deflate(&strm, Z_FINISH);
    if (ret != Z_STREAM_END) {
        free(buf);
        deflateEnd(&strm);
        return ret == Z_OK ? Z_BUF_ERROR : ret;
    }

    *out_len = (size_t)strm.total_out;
    *out_buf = buf;
    deflateEnd(&strm);
    return Z_OK;
}

uint32_t czlib_crc32(uint32_t crc, const uint8_t *buf, size_t len) {
    return (uint32_t)crc32((uLong)crc, (const Bytef *)buf, (uInt)len);
}

void czlib_free(void *ptr) {
    free(ptr);
}
