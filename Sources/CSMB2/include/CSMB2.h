// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef RENPLAY_CSMB2_H
#define RENPLAY_CSMB2_H

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *host;
    int port;
    const char *username;
    const char *password;
    const char *domain;
    int is_guest;
} csmb_credentials_t;

typedef struct {
    char *name;
    char *remark;
    int is_hidden;
} csmb_share_entry_t;

typedef struct {
    csmb_share_entry_t *items;
    size_t count;
} csmb_share_list_t;

typedef struct {
    char *name;
    int is_dir;
    uint64_t size;
    uint64_t mtime;
} csmb_dir_entry_t;

typedef struct {
    csmb_dir_entry_t *items;
    size_t count;
} csmb_dir_list_t;

typedef struct csmb_conn csmb_conn_t;

int csmb_list_shares(
    const csmb_credentials_t *creds,
    csmb_share_list_t *out_list,
    char *err_buf,
    size_t err_len
);

void csmb_free_share_list(csmb_share_list_t *list);

csmb_conn_t *csmb_connect(
    const csmb_credentials_t *creds,
    const char *share,
    char *err_buf,
    size_t err_len
);

void csmb_disconnect(csmb_conn_t *conn);

int csmb_conn_list_dir(
    csmb_conn_t *conn,
    const char *rel_path,
    csmb_dir_list_t *out_list,
    char *err_buf,
    size_t err_len
);

void csmb_free_dir_list(csmb_dir_list_t *list);

int csmb_conn_stat(
    csmb_conn_t *conn,
    const char *rel_path,
    uint64_t *out_size,
    int *out_is_dir,
    char *err_buf,
    size_t err_len
);

ssize_t csmb_conn_pread(
    csmb_conn_t *conn,
    const char *rel_path,
    uint64_t offset,
    void *buf,
    size_t length,
    char *err_buf,
    size_t err_len
);

int csmb_conn_read_file(
    csmb_conn_t *conn,
    const char *rel_path,
    size_t max_bytes,
    uint8_t **out_buf,
    size_t *out_len,
    char *err_buf,
    size_t err_len
);

void csmb_free_buffer(void *buf);

int csmb_mount_configure(
    const csmb_credentials_t *creds,
    const char *share,
    const char *base_rel_path,
    char *err_buf,
    size_t err_len
);

void csmb_mount_clear(void);

int csmb_mount_is_active(void);

ssize_t csmb_mount_pread(
    const char *game_rel_path,
    uint64_t offset,
    void *buf,
    size_t length
);

#ifdef __cplusplus
}
#endif

#endif
