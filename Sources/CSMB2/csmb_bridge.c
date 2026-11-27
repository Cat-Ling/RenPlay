// SPDX-FileCopyrightText: 2026 RenPlay Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "CSMB2.h"

#include "smb2.h"
#include "libsmb2.h"
#include "libsmb2-dcerpc.h"
#include "libsmb2-dcerpc-srvsvc.h"
#include "libsmb2-raw.h"
#include "libsmb2-private.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CSMB_FH_CACHE_SLOTS 8
#define CSMB_BLOCK_SIZE (256u * 1024u)
#define CSMB_BLOCK_CACHE_SLOTS 128u
#define CSMB_SMALL_CACHE_THRESHOLD (1024u * 1024u)
#define CSMB_TIMEOUT_SEC 15

static void csmb_set_error(char *err_buf, size_t err_len, const char *msg) {
    if (!err_buf || err_len == 0) {
        return;
    }
    if (!msg) {
        err_buf[0] = '\0';
        return;
    }
    snprintf(err_buf, err_len, "%s", msg);
}

static char *csmb_strdup_safe(const char *s) {
    if (!s) {
        return strdup("");
    }
    return strdup(s);
}

// Normalize share-relative SMB paths to forward-slash form without leading/trailing slashes and reject traversal.
static int csmb_normalize_rel_path(const char *input, char *out, size_t out_len) {
    if (!out || out_len == 0) {
        return -EINVAL;
    }
    if (!input || input[0] == '\0') {
        out[0] = '\0';
        return 0;
    }

    size_t j = 0;
    size_t i = 0;
    while (input[i] == '/' || input[i] == '\\') {
        i++;
    }

    int last_was_slash = 1;
    for (; input[i] != '\0'; i++) {
        char ch = input[i];
        if (ch == '\\') {
            ch = '/';
        }
        if (ch == '/' && last_was_slash) {
            continue;
        }
        if (j + 1 >= out_len) {
            return -ENAMETOOLONG;
        }
        out[j++] = ch;
        last_was_slash = (ch == '/');
    }
    while (j > 0 && out[j - 1] == '/') {
        j--;
    }
    out[j] = '\0';

    // Reject '.' and '..' path components.
    const char *p = out;
    while (*p != '\0') {
        const char *slash = strchr(p, '/');
        size_t seg_len = slash ? (size_t)(slash - p) : strlen(p);
        if ((seg_len == 1 && p[0] == '.') || (seg_len == 2 && p[0] == '.' && p[1] == '.')) {
            return -EINVAL;
        }
        if (!slash) {
            break;
        }
        p = slash + 1;
    }
    return 0;
}

static int csmb_join_rel_path(const char *base, const char *sub, char *out, size_t out_len) {
    char nb[2048];
    char ns[2048];
    if (csmb_normalize_rel_path(base, nb, sizeof(nb)) < 0) {
        return -EINVAL;
    }
    if (csmb_normalize_rel_path(sub, ns, sizeof(ns)) < 0) {
        return -EINVAL;
    }
    if (nb[0] == '\0') {
        snprintf(out, out_len, "%s", ns);
        return 0;
    }
    if (ns[0] == '\0') {
        snprintf(out, out_len, "%s", nb);
        return 0;
    }
    if (strlen(nb) + 1 + strlen(ns) + 1 > out_len) {
        return -ENAMETOOLONG;
    }
    snprintf(out, out_len, "%s/%s", nb, ns);
    return 0;
}

static void csmb_format_server(const char *host, int port, char *out, size_t out_len) {
    if (!host) {
        out[0] = '\0';
        return;
    }
    int effective_port = (port > 0 && port <= 65535) ? port : 445;
    if (effective_port == 445) {
        snprintf(out, out_len, "%s", host);
        return;
    }
    if (strchr(host, ':') != NULL && host[0] != '[') {
        snprintf(out, out_len, "[%s]:%d", host, effective_port);
    } else {
        snprintf(out, out_len, "%s:%d", host, effective_port);
    }
}

static int csmb_connect_attempt(
    const char *server_spec,
    const char *share,
    const char *user,
    const char *password,
    const char *domain,
    struct smb2_context **out_smb2,
    char *err_buf,
    size_t err_len
) {
    struct smb2_context *smb2 = smb2_init_context();
    if (!smb2) {
        csmb_set_error(err_buf, err_len, "Failed to allocate SMB2 context.");
        return -ENOMEM;
    }

    smb2_set_security_mode(smb2, SMB2_NEGOTIATE_SIGNING_ENABLED);
    smb2_set_authentication(smb2, SMB2_SEC_NTLMSSP);
    smb2_set_timeout(smb2, CSMB_TIMEOUT_SEC);
    smb2_set_workstation(smb2, "RenPlay");
    smb2_set_user(smb2, user ? user : "");
    smb2_set_password(smb2, password ? password : "");
    if (domain && domain[0] != '\0') {
        smb2_set_domain(smb2, domain);
    }

    int rc = smb2_connect_share(smb2, server_spec, share, user ? user : "");
    if (rc < 0) {
        const char *msg = smb2_get_error(smb2);
        csmb_set_error(err_buf, err_len, (msg && msg[0]) ? msg : strerror(-rc));
        smb2_destroy_context(smb2);
        return rc;
    }

    *out_smb2 = smb2;
    return 0;
}

static int csmb_open_share_context(
    const csmb_credentials_t *creds,
    const char *share,
    struct smb2_context **out_smb2,
    char *err_buf,
    size_t err_len
) {
    if (!creds || !creds->host || creds->host[0] == '\0' || !share || share[0] == '\0') {
        csmb_set_error(err_buf, err_len, "Missing SMB host or share name.");
        return -EINVAL;
    }

    char server_spec[512];
    csmb_format_server(creds->host, creds->port, server_spec, sizeof(server_spec));

    int guest_mode = creds->is_guest || !creds->username || creds->username[0] == '\0';
    if (!guest_mode) {
        return csmb_connect_attempt(
            server_spec,
            share,
            creds->username,
            creds->password ? creds->password : "",
            creds->domain,
            out_smb2,
            err_buf,
            err_len
        );
    }

    // Some NAS servers require an empty anonymous user while Windows/macOS guest shares expect "Guest".
    int rc = csmb_connect_attempt(server_spec, share, "", "", creds->domain, out_smb2, err_buf, err_len);
    if (rc == 0) {
        return 0;
    }
    char first_err[512];
    snprintf(first_err, sizeof(first_err), "%s", (err_buf && err_len > 0) ? err_buf : "");

    int rc_guest = csmb_connect_attempt(server_spec, share, "Guest", "", creds->domain, out_smb2, err_buf, err_len);
    if (rc_guest == 0) {
        return 0;
    }
    if (first_err[0] != '\0') {
        csmb_set_error(err_buf, err_len, first_err);
    }
    return rc_guest;
}

typedef struct {
    int finished;
    int status;
    csmb_share_list_t *list;
    char err_msg[512];
} csmb_share_enum_state_t;

static void csmb_share_enum_cb(struct smb2_context *smb2, int status, void *command_data, void *private_data) {
    csmb_share_enum_state_t *st = (csmb_share_enum_state_t *)private_data;
    struct srvsvc_NetrShareEnum_rep *rep = (struct srvsvc_NetrShareEnum_rep *)command_data;

    if (status != 0) {
        st->status = status < 0 ? status : -EIO;
        const char *m = smb2_get_error(smb2);
        snprintf(st->err_msg, sizeof(st->err_msg), "%s", (m && m[0]) ? m : "Share enumeration failed.");
        st->finished = 1;
        return;
    }

    if (rep && rep->ses.Level == SHARE_INFO_1 && rep->ses.ShareInfo.Level1.Buffer) {
        uint32_t total = rep->ses.ShareInfo.Level1.EntriesRead;
        struct srvsvc_SHARE_INFO_1 *arr = rep->ses.ShareInfo.Level1.Buffer->share_info_1;

        csmb_share_entry_t *items = calloc(total > 0 ? total : 1, sizeof(csmb_share_entry_t));
        size_t kept = 0;
        if (items) {
            for (uint32_t i = 0; i < total; i++) {
                uint32_t base_type = arr[i].type & 0x3u;
                if (base_type != SHARE_TYPE_DISKTREE) {
                    continue;
                }
                const char *name = arr[i].netname.utf8;
                if (!name || name[0] == '\0') {
                    continue;
                }
                size_t nlen = strlen(name);
                int is_hidden = ((arr[i].type & SHARE_TYPE_HIDDEN) != 0) || (nlen > 0 && name[nlen - 1] == '$');
                items[kept].name = csmb_strdup_safe(name);
                items[kept].remark = csmb_strdup_safe(arr[i].remark.utf8);
                items[kept].is_hidden = is_hidden ? 1 : 0;
                kept++;
            }
            st->list->items = items;
            st->list->count = kept;
        }
    }

    if (rep) {
        smb2_free_data(smb2, rep);
    }
    st->status = 0;
    st->finished = 1;
}

int csmb_list_shares(
    const csmb_credentials_t *creds,
    csmb_share_list_t *out_list,
    char *err_buf,
    size_t err_len
) {
    if (!out_list) {
        return -EINVAL;
    }
    out_list->items = NULL;
    out_list->count = 0;

    struct smb2_context *smb2 = NULL;
    int rc = csmb_open_share_context(creds, "IPC$", &smb2, err_buf, err_len);
    if (rc < 0) {
        return rc;
    }

    csmb_share_enum_state_t state;
    memset(&state, 0, sizeof(state));
    state.list = out_list;

    if (smb2_share_enum_async(smb2, SHARE_INFO_1, csmb_share_enum_cb, &state) != 0) {
        csmb_set_error(err_buf, err_len, smb2_get_error(smb2));
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        return -EIO;
    }

    time_t started = time(NULL);
    while (!state.finished) {
        if (time(NULL) - started > CSMB_TIMEOUT_SEC) {
            csmb_set_error(err_buf, err_len, "Timed out enumerating SMB shares.");
            smb2_disconnect_share(smb2);
            smb2_destroy_context(smb2);
            csmb_free_share_list(out_list);
            return -ETIMEDOUT;
        }
        struct pollfd pfd;
        memset(&pfd, 0, sizeof(pfd));
        pfd.fd = smb2_get_fd(smb2);
        pfd.events = (short)smb2_which_events(smb2);
        int prc = poll(&pfd, 1, 1000);
        if (prc < 0) {
            if (errno == EINTR) {
                continue;
            }
            csmb_set_error(err_buf, err_len, strerror(errno));
            smb2_disconnect_share(smb2);
            smb2_destroy_context(smb2);
            csmb_free_share_list(out_list);
            return -errno;
        }
        if (pfd.revents != 0) {
            if (smb2_service(smb2, pfd.revents) < 0) {
                csmb_set_error(err_buf, err_len, smb2_get_error(smb2));
                smb2_disconnect_share(smb2);
                smb2_destroy_context(smb2);
                csmb_free_share_list(out_list);
                return -EIO;
            }
        }
    }

    smb2_disconnect_share(smb2);
    smb2_destroy_context(smb2);

    if (state.status != 0) {
        csmb_set_error(err_buf, err_len, state.err_msg[0] ? state.err_msg : "Failed to list SMB shares.");
        csmb_free_share_list(out_list);
        return state.status;
    }
    return 0;
}

void csmb_free_share_list(csmb_share_list_t *list) {
    if (!list || !list->items) {
        return;
    }
    for (size_t i = 0; i < list->count; i++) {
        free(list->items[i].name);
        free(list->items[i].remark);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
}

struct csmb_conn {
    struct smb2_context *smb2;
    struct smb2fh *cached_fh;
    char *cached_path;
};

static void csmb_conn_close_cached_fh(csmb_conn_t *conn) {
    if (!conn) {
        return;
    }
    if (conn->cached_fh && conn->smb2) {
        smb2_close(conn->smb2, conn->cached_fh);
    }
    conn->cached_fh = NULL;
    free(conn->cached_path);
    conn->cached_path = NULL;
}

csmb_conn_t *csmb_connect(
    const csmb_credentials_t *creds,
    const char *share,
    char *err_buf,
    size_t err_len
) {
    struct smb2_context *smb2 = NULL;
    if (csmb_open_share_context(creds, share, &smb2, err_buf, err_len) < 0) {
        return NULL;
    }
    csmb_conn_t *conn = calloc(1, sizeof(csmb_conn_t));
    if (!conn) {
        smb2_disconnect_share(smb2);
        smb2_destroy_context(smb2);
        csmb_set_error(err_buf, err_len, "Out of memory.");
        return NULL;
    }
    conn->smb2 = smb2;
    return conn;
}

void csmb_disconnect(csmb_conn_t *conn) {
    if (!conn) {
        return;
    }
    csmb_conn_close_cached_fh(conn);
    if (conn->smb2) {
        smb2_disconnect_share(conn->smb2);
        smb2_destroy_context(conn->smb2);
        conn->smb2 = NULL;
    }
    free(conn);
}

int csmb_conn_list_dir(
    csmb_conn_t *conn,
    const char *rel_path,
    csmb_dir_list_t *out_list,
    char *err_buf,
    size_t err_len
) {
    if (!conn || !conn->smb2 || !out_list) {
        return -EINVAL;
    }
    out_list->items = NULL;
    out_list->count = 0;

    char norm[2048];
    if (csmb_normalize_rel_path(rel_path, norm, sizeof(norm)) < 0) {
        csmb_set_error(err_buf, err_len, "Invalid SMB directory path.");
        return -EINVAL;
    }

    struct smb2dir *dir = smb2_opendir(conn->smb2, norm);
    if (!dir) {
        csmb_set_error(err_buf, err_len, smb2_get_error(conn->smb2));
        return -EIO;
    }

    size_t cap = 32;
    size_t count = 0;
    csmb_dir_entry_t *items = calloc(cap, sizeof(csmb_dir_entry_t));
    if (!items) {
        smb2_closedir(conn->smb2, dir);
        return -ENOMEM;
    }

    struct smb2dirent *ent;
    while ((ent = smb2_readdir(conn->smb2, dir)) != NULL) {
        if (!ent->name || strcmp(ent->name, ".") == 0 || strcmp(ent->name, "..") == 0) {
            continue;
        }
        if (count == cap) {
            size_t new_cap = cap * 2;
            csmb_dir_entry_t *grown = realloc(items, new_cap * sizeof(csmb_dir_entry_t));
            if (!grown) {
                smb2_closedir(conn->smb2, dir);
                out_list->items = items;
                out_list->count = count;
                csmb_free_dir_list(out_list);
                return -ENOMEM;
            }
            items = grown;
            cap = new_cap;
        }
        items[count].name = csmb_strdup_safe(ent->name);
        items[count].is_dir = (ent->st.smb2_type == SMB2_TYPE_DIRECTORY) ? 1 : 0;
        items[count].size = ent->st.smb2_size;
        items[count].mtime = ent->st.smb2_mtime;
        count++;
    }

    smb2_closedir(conn->smb2, dir);
    out_list->items = items;
    out_list->count = count;
    return 0;
}

void csmb_free_dir_list(csmb_dir_list_t *list) {
    if (!list || !list->items) {
        return;
    }
    for (size_t i = 0; i < list->count; i++) {
        free(list->items[i].name);
    }
    free(list->items);
    list->items = NULL;
    list->count = 0;
}

int csmb_conn_stat(
    csmb_conn_t *conn,
    const char *rel_path,
    uint64_t *out_size,
    int *out_is_dir,
    char *err_buf,
    size_t err_len
) {
    if (!conn || !conn->smb2) {
        return -EINVAL;
    }
    char norm[2048];
    if (csmb_normalize_rel_path(rel_path, norm, sizeof(norm)) < 0) {
        csmb_set_error(err_buf, err_len, "Invalid SMB path.");
        return -EINVAL;
    }
    struct smb2_stat_64 st;
    memset(&st, 0, sizeof(st));
    int rc = smb2_stat(conn->smb2, norm, &st);
    if (rc < 0) {
        csmb_set_error(err_buf, err_len, smb2_get_error(conn->smb2));
        return rc;
    }
    if (out_size) *out_size = st.smb2_size;
    if (out_is_dir) *out_is_dir = (st.smb2_type == SMB2_TYPE_DIRECTORY) ? 1 : 0;
    return 0;
}

static ssize_t csmb_pread_loop(
    struct smb2_context *smb2,
    struct smb2fh *fh,
    uint64_t offset,
    uint8_t *dst,
    size_t length
) {
    uint32_t max_chunk = smb2_get_max_read_size(smb2);
    if (max_chunk == 0 || max_chunk > (1024u * 1024u)) {
        max_chunk = 65536u;
    }
    size_t total = 0;
    while (total < length) {
        size_t remain = length - total;
        uint32_t want = remain > max_chunk ? max_chunk : (uint32_t)remain;
        int got = smb2_pread(smb2, fh, dst + total, want, offset + total);
        if (got < 0) {
            return total > 0 ? (ssize_t)total : (ssize_t)got;
        }
        if (got == 0) {
            break;
        }
        total += (size_t)got;
        if ((uint32_t)got < want) {
            break;
        }
    }
    return (ssize_t)total;
}

ssize_t csmb_conn_pread(
    csmb_conn_t *conn,
    const char *rel_path,
    uint64_t offset,
    void *buf,
    size_t length,
    char *err_buf,
    size_t err_len
) {
    if (!conn || !conn->smb2 || !rel_path || (!buf && length > 0)) {
        return -EINVAL;
    }
    if (length == 0) {
        return 0;
    }
    char norm[2048];
    if (csmb_normalize_rel_path(rel_path, norm, sizeof(norm)) < 0 || norm[0] == '\0') {
        csmb_set_error(err_buf, err_len, "Invalid SMB file path.");
        return -EINVAL;
    }

    if (!conn->cached_fh || !conn->cached_path || strcmp(conn->cached_path, norm) != 0) {
        csmb_conn_close_cached_fh(conn);
        struct smb2fh *fh = smb2_open(conn->smb2, norm, O_RDONLY);
        if (!fh) {
            csmb_set_error(err_buf, err_len, smb2_get_error(conn->smb2));
            return -EIO;
        }
        conn->cached_fh = fh;
        conn->cached_path = csmb_strdup_safe(norm);
    }

    ssize_t n = csmb_pread_loop(conn->smb2, conn->cached_fh, offset, (uint8_t *)buf, length);
    if (n < 0) {
        csmb_set_error(err_buf, err_len, smb2_get_error(conn->smb2));
        csmb_conn_close_cached_fh(conn);
    }
    return n;
}

int csmb_conn_read_file(
    csmb_conn_t *conn,
    const char *rel_path,
    size_t max_bytes,
    uint8_t **out_buf,
    size_t *out_len,
    char *err_buf,
    size_t err_len
) {
    if (!conn || !conn->smb2 || !rel_path || !out_buf || !out_len) {
        return -EINVAL;
    }
    *out_buf = NULL;
    *out_len = 0;

    char norm[2048];
    if (csmb_normalize_rel_path(rel_path, norm, sizeof(norm)) < 0 || norm[0] == '\0') {
        csmb_set_error(err_buf, err_len, "Invalid SMB file path.");
        return -EINVAL;
    }

    csmb_conn_close_cached_fh(conn);
    struct smb2fh *fh = smb2_open(conn->smb2, norm, O_RDONLY);
    if (!fh) {
        csmb_set_error(err_buf, err_len, smb2_get_error(conn->smb2));
        return -ENOENT;
    }

    struct smb2_stat_64 st;
    memset(&st, 0, sizeof(st));
    if (smb2_fstat(conn->smb2, fh, &st) < 0) {
        csmb_set_error(err_buf, err_len, smb2_get_error(conn->smb2));
        smb2_close(conn->smb2, fh);
        return -EIO;
    }
    if (max_bytes > 0 && st.smb2_size > (uint64_t)max_bytes) {
        csmb_set_error(err_buf, err_len, "Remote file exceeds maximum read limit.");
        smb2_close(conn->smb2, fh);
        return -EFBIG;
    }

    size_t target_len = (size_t)st.smb2_size;
    uint8_t *data = malloc(target_len > 0 ? target_len : 1);
    if (!data) {
        smb2_close(conn->smb2, fh);
        return -ENOMEM;
    }

    ssize_t got = target_len > 0 ? csmb_pread_loop(conn->smb2, fh, 0, data, target_len) : 0;
    smb2_close(conn->smb2, fh);

    if (got < 0) {
        free(data);
        csmb_set_error(err_buf, err_len, "Failed reading remote SMB file.");
        return (int)got;
    }

    *out_buf = data;
    *out_len = (size_t)got;
    return 0;
}

void csmb_free_buffer(void *buf) {
    free(buf);
}

// Persistent, thread-safe SMB mount with open file handle LRU and 32 MiB block cache for active gameplay.
typedef struct {
    char *rel_path;
    struct smb2fh *fh;
    uint64_t last_used;
} csmb_fh_slot_t;

typedef struct {
    char *rel_path;
    uint64_t block_offset;
    uint8_t *data;
    size_t valid_len;
    uint64_t last_used;
} csmb_block_slot_t;

typedef struct {
    int active;
    char *host;
    int port;
    char *username;
    char *password;
    char *domain;
    int is_guest;
    char *share;
    char *base_rel_path;
    struct smb2_context *smb2;
    csmb_fh_slot_t fh_cache[CSMB_FH_CACHE_SLOTS];
    csmb_block_slot_t block_cache[CSMB_BLOCK_CACHE_SLOTS];
    uint64_t tick;
} csmb_mount_state_t;

static pthread_mutex_t g_mount_lock = PTHREAD_MUTEX_INITIALIZER;
static csmb_mount_state_t g_mount = {0};

static void csmb_mount_close_all_handles_locked(void) {
    for (int i = 0; i < CSMB_FH_CACHE_SLOTS; i++) {
        if (g_mount.fh_cache[i].fh && g_mount.smb2) {
            smb2_close(g_mount.smb2, g_mount.fh_cache[i].fh);
        }
        g_mount.fh_cache[i].fh = NULL;
        free(g_mount.fh_cache[i].rel_path);
        g_mount.fh_cache[i].rel_path = NULL;
        g_mount.fh_cache[i].last_used = 0;
    }
}

static void csmb_mount_clear_blocks_locked(void) {
    for (size_t i = 0; i < CSMB_BLOCK_CACHE_SLOTS; i++) {
        free(g_mount.block_cache[i].rel_path);
        g_mount.block_cache[i].rel_path = NULL;
        free(g_mount.block_cache[i].data);
        g_mount.block_cache[i].data = NULL;
        g_mount.block_cache[i].block_offset = 0;
        g_mount.block_cache[i].valid_len = 0;
        g_mount.block_cache[i].last_used = 0;
    }
}

static void csmb_mount_reset_locked(void) {
    csmb_mount_close_all_handles_locked();
    csmb_mount_clear_blocks_locked();
    if (g_mount.smb2) {
        smb2_disconnect_share(g_mount.smb2);
        smb2_destroy_context(g_mount.smb2);
        g_mount.smb2 = NULL;
    }
    free(g_mount.host);
    free(g_mount.username);
    free(g_mount.password);
    free(g_mount.domain);
    free(g_mount.share);
    free(g_mount.base_rel_path);
    memset(&g_mount, 0, sizeof(g_mount));
}

static int csmb_mount_reconnect_locked(char *err_buf, size_t err_len) {
    csmb_mount_close_all_handles_locked();
    if (g_mount.smb2) {
        smb2_disconnect_share(g_mount.smb2);
        smb2_destroy_context(g_mount.smb2);
        g_mount.smb2 = NULL;
    }
    csmb_credentials_t creds = {
        .host = g_mount.host,
        .port = g_mount.port,
        .username = g_mount.username,
        .password = g_mount.password,
        .domain = g_mount.domain,
        .is_guest = g_mount.is_guest,
    };
    return csmb_open_share_context(&creds, g_mount.share, &g_mount.smb2, err_buf, err_len);
}

int csmb_mount_configure(
    const csmb_credentials_t *creds,
    const char *share,
    const char *base_rel_path,
    char *err_buf,
    size_t err_len
) {
    if (!creds || !creds->host || !share) {
        csmb_set_error(err_buf, err_len, "Missing SMB mount configuration.");
        return -EINVAL;
    }

    char norm_base[2048];
    if (csmb_normalize_rel_path(base_rel_path, norm_base, sizeof(norm_base)) < 0) {
        csmb_set_error(err_buf, err_len, "Invalid SMB base path.");
        return -EINVAL;
    }

    pthread_mutex_lock(&g_mount_lock);
    csmb_mount_reset_locked();

    g_mount.host = csmb_strdup_safe(creds->host);
    g_mount.port = (creds->port > 0 && creds->port <= 65535) ? creds->port : 445;
    g_mount.username = csmb_strdup_safe(creds->username);
    g_mount.password = csmb_strdup_safe(creds->password);
    g_mount.domain = csmb_strdup_safe(creds->domain);
    g_mount.is_guest = creds->is_guest ? 1 : 0;
    g_mount.share = csmb_strdup_safe(share);
    g_mount.base_rel_path = csmb_strdup_safe(norm_base);

    int rc = csmb_mount_reconnect_locked(err_buf, err_len);
    if (rc < 0) {
        csmb_mount_reset_locked();
        pthread_mutex_unlock(&g_mount_lock);
        return rc;
    }

    g_mount.active = 1;
    pthread_mutex_unlock(&g_mount_lock);
    return 0;
}

void csmb_mount_clear(void) {
    pthread_mutex_lock(&g_mount_lock);
    csmb_mount_reset_locked();
    pthread_mutex_unlock(&g_mount_lock);
}

int csmb_mount_is_active(void) {
    pthread_mutex_lock(&g_mount_lock);
    int active = g_mount.active ? 1 : 0;
    pthread_mutex_unlock(&g_mount_lock);
    return active;
}

static struct smb2fh *csmb_mount_acquire_fh_locked(const char *share_rel_path, int *out_err) {
    if (!g_mount.smb2) {
        if (csmb_mount_reconnect_locked(NULL, 0) < 0) {
            if (out_err) *out_err = -ENOTCONN;
            return NULL;
        }
    }

    int empty_idx = -1;
    int lru_idx = 0;
    uint64_t oldest_tick = UINT64_MAX;
    for (int i = 0; i < CSMB_FH_CACHE_SLOTS; i++) {
        if (g_mount.fh_cache[i].fh && g_mount.fh_cache[i].rel_path &&
            strcmp(g_mount.fh_cache[i].rel_path, share_rel_path) == 0) {
            g_mount.fh_cache[i].last_used = ++g_mount.tick;
            return g_mount.fh_cache[i].fh;
        }
        if (!g_mount.fh_cache[i].fh && empty_idx < 0) {
            empty_idx = i;
        }
        if (g_mount.fh_cache[i].last_used < oldest_tick) {
            oldest_tick = g_mount.fh_cache[i].last_used;
            lru_idx = i;
        }
    }

    struct smb2fh *fh = smb2_open(g_mount.smb2, share_rel_path, O_RDONLY);
    if (!fh) {
        int nterr = smb2_get_nterror(g_mount.smb2);
        // Reconnect once in case the NAS closed the idle TCP session between dialogues.
        if (nterr == 0) {
            if (csmb_mount_reconnect_locked(NULL, 0) == 0) {
                fh = smb2_open(g_mount.smb2, share_rel_path, O_RDONLY);
            }
        }
        if (!fh) {
            if (out_err) *out_err = -ENOENT;
            return NULL;
        }
    }

    int slot = empty_idx >= 0 ? empty_idx : lru_idx;
    if (g_mount.fh_cache[slot].fh && g_mount.smb2) {
        smb2_close(g_mount.smb2, g_mount.fh_cache[slot].fh);
    }
    free(g_mount.fh_cache[slot].rel_path);
    g_mount.fh_cache[slot].rel_path = csmb_strdup_safe(share_rel_path);
    g_mount.fh_cache[slot].fh = fh;
    g_mount.fh_cache[slot].last_used = ++g_mount.tick;
    return fh;
}

static void csmb_mount_invalidate_fh_locked(const char *share_rel_path) {
    for (int i = 0; i < CSMB_FH_CACHE_SLOTS; i++) {
        if (g_mount.fh_cache[i].fh && g_mount.fh_cache[i].rel_path &&
            strcmp(g_mount.fh_cache[i].rel_path, share_rel_path) == 0) {
            if (g_mount.smb2) {
                smb2_close(g_mount.smb2, g_mount.fh_cache[i].fh);
            }
            g_mount.fh_cache[i].fh = NULL;
            free(g_mount.fh_cache[i].rel_path);
            g_mount.fh_cache[i].rel_path = NULL;
            g_mount.fh_cache[i].last_used = 0;
        }
    }
}

static ssize_t csmb_mount_raw_pread_locked(
    const char *share_rel_path,
    uint64_t offset,
    uint8_t *dst,
    size_t length
) {
    for (int attempt = 0; attempt < 2; attempt++) {
        int err = 0;
        struct smb2fh *fh = csmb_mount_acquire_fh_locked(share_rel_path, &err);
        if (!fh) {
            return err ? err : -EIO;
        }
        ssize_t got = csmb_pread_loop(g_mount.smb2, fh, offset, dst, length);
        if (got >= 0) {
            return got;
        }
        csmb_mount_invalidate_fh_locked(share_rel_path);
        if (csmb_mount_reconnect_locked(NULL, 0) < 0) {
            return got;
        }
    }
    return -EIO;
}

static const csmb_block_slot_t *csmb_mount_get_block_locked(const char *share_rel_path, uint64_t block_offset) {
    size_t empty_idx = CSMB_BLOCK_CACHE_SLOTS;
    size_t lru_idx = 0;
    uint64_t oldest = UINT64_MAX;

    for (size_t i = 0; i < CSMB_BLOCK_CACHE_SLOTS; i++) {
        csmb_block_slot_t *b = &g_mount.block_cache[i];
        if (b->data && b->block_offset == block_offset && b->rel_path &&
            strcmp(b->rel_path, share_rel_path) == 0) {
            b->last_used = ++g_mount.tick;
            return b;
        }
        if (!b->data && empty_idx == CSMB_BLOCK_CACHE_SLOTS) {
            empty_idx = i;
        }
        if (b->last_used < oldest) {
            oldest = b->last_used;
            lru_idx = i;
        }
    }

    uint8_t *buf = malloc(CSMB_BLOCK_SIZE);
    if (!buf) {
        return NULL;
    }
    ssize_t got = csmb_mount_raw_pread_locked(share_rel_path, block_offset, buf, CSMB_BLOCK_SIZE);
    if (got < 0) {
        free(buf);
        return NULL;
    }

    size_t slot_idx = empty_idx < CSMB_BLOCK_CACHE_SLOTS ? empty_idx : lru_idx;
    csmb_block_slot_t *slot = &g_mount.block_cache[slot_idx];
    free(slot->rel_path);
    free(slot->data);
    slot->rel_path = csmb_strdup_safe(share_rel_path);
    slot->block_offset = block_offset;
    slot->data = buf;
    slot->valid_len = (size_t)got;
    slot->last_used = ++g_mount.tick;
    return slot;
}

ssize_t csmb_mount_pread(
    const char *game_rel_path,
    uint64_t offset,
    void *buf,
    size_t length
) {
    if (!game_rel_path || (!buf && length > 0)) {
        return -EINVAL;
    }
    if (length == 0) {
        return 0;
    }

    pthread_mutex_lock(&g_mount_lock);
    if (!g_mount.active) {
        pthread_mutex_unlock(&g_mount_lock);
        return -ENOTCONN;
    }

    char full_rel[2048];
    if (csmb_join_rel_path(g_mount.base_rel_path, game_rel_path, full_rel, sizeof(full_rel)) < 0 ||
        full_rel[0] == '\0') {
        pthread_mutex_unlock(&g_mount_lock);
        return -EINVAL;
    }

    uint8_t *dst = (uint8_t *)buf;
    if (length >= CSMB_SMALL_CACHE_THRESHOLD) {
        ssize_t direct = csmb_mount_raw_pread_locked(full_rel, offset, dst, length);
        pthread_mutex_unlock(&g_mount_lock);
        return direct;
    }

    size_t total = 0;
    while (total < length) {
        uint64_t cur_off = offset + total;
        uint64_t block_off = cur_off & ~((uint64_t)CSMB_BLOCK_SIZE - 1u);
        size_t in_block = (size_t)(cur_off - block_off);

        const csmb_block_slot_t *blk = csmb_mount_get_block_locked(full_rel, block_off);
        if (!blk) {
            ssize_t fallback = csmb_mount_raw_pread_locked(full_rel, cur_off, dst + total, length - total);
            if (fallback < 0) {
                pthread_mutex_unlock(&g_mount_lock);
                return total > 0 ? (ssize_t)total : fallback;
            }
            total += (size_t)fallback;
            break;
        }
        if (in_block >= blk->valid_len) {
            break;
        }
        size_t avail = blk->valid_len - in_block;
        size_t want = length - total;
        size_t take = avail < want ? avail : want;
        memcpy(dst + total, blk->data + in_block, take);
        total += take;
        if (blk->valid_len < CSMB_BLOCK_SIZE) {
            break;
        }
    }

    pthread_mutex_unlock(&g_mount_lock);
    return (ssize_t)total;
}
