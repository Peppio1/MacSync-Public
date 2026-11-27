// Diagnostic only. No writes, no queue or filesystem mutation authority.
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <dirent.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { LIMIT = 4096, BUFFER = 65536, REGULAR = 1, DIRECTORY = 2, SYMLINK = 5 };
struct row {
    char *name;
    uint32_t type;
    dev_t device;
    uint64_t inode;
    struct timespec modified, changed;
    off_t size;
};
struct rows { struct row *v; size_t n; };
static double tick(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static int take(const unsigned char **p, const unsigned char *end, void *out, size_t n) {
    size_t aligned = (n + 3u) & ~(size_t)3u;
    if (*p > end || (size_t)(end - *p) < aligned) return 0;
    memcpy(out, *p, n);
    *p += aligned;
    return 1;
}
static int append(struct rows *a, struct row value, const char *name) {
    if (a->n >= LIMIT || !name[0] || strchr(name, '/') ||
        !strcmp(name, ".") || !strcmp(name, "..")) return 0;
    for (size_t i = 0; i < a->n; i++)
        if (!strcmp(a->v[i].name, name)) return 0;
    value.name = strdup(name);
    if (!value.name) return 0;
    a->v[a->n++] = value;
    return 1;
}
static void dispose(struct rows *a) {
    for (size_t i = 0; i < a->n; i++) free(a->v[i].name);
    free(a->v);
}
static uint32_t object_type(mode_t m) {
    if (S_ISREG(m)) return REGULAR;
    if (S_ISDIR(m)) return DIRECTORY;
    if (S_ISLNK(m)) return SYMLINK;
    return 0;
}
static int baseline(int root, struct rows *out) {
    int fd = openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return 0;
    DIR *dir = fdopendir(fd);
    if (!dir) { close(fd); return 0; }
    int ok = 1;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) { if (errno) ok = 0; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        struct stat st;
        if (fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW)) { ok = 0; break; }
        struct row value = { .type = object_type(st.st_mode), .device = st.st_dev,
            .inode = st.st_ino, .modified = st.st_mtimespec,
            .changed = st.st_ctimespec, .size = st.st_size };
        if (!value.type || !append(out, value, entry->d_name)) { ok = 0; break; }
    }
    closedir(dir);
    return ok;
}
static int bulk(int root, struct rows *out) {
    int fd = openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return 0;
    unsigned char *buffer = malloc(BUFFER);
    if (!buffer) { close(fd); return 0; }
    struct attrlist attrs = {0};
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    const attrgroup_t required = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME |
        ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME |
        ATTR_CMN_CHGTIME | ATTR_CMN_FILEID;
    attrs.commonattr = required | ATTR_CMN_ERROR;
    attrs.fileattr = ATTR_FILE_DATALENGTH;
    int ok = 1, batches = 0;
    while (ok) {
        int n = getattrlistbulk(fd, &attrs, buffer, BUFFER, 0);
        if (n < 0) { printf("BULK_UNAVAILABLE errno=%d\n", errno); ok = 0; break; }
        if (!n) break;
        batches++;
        const unsigned char *p = buffer, *limit = buffer + BUFFER;
        for (int i = 0; i < n; i++) {
            const unsigned char *start = p;
            uint32_t length;
            if (!take(&p, limit, &length, sizeof(length)) ||
                length < sizeof(length) + sizeof(attribute_set_t) ||
                length > (size_t)(limit - start)) { ok = 0; break; }
            const unsigned char *end = start + length;
            attribute_set_t returned;
            if (!take(&p, end, &returned, sizeof(returned))) { ok = 0; break; }
            if (returned.commonattr & ATTR_CMN_ERROR) {
                uint32_t error;
                if (!take(&p, end, &error, sizeof(error)) || error) {
                    printf("BULK_ENTRY_ERROR\n"); ok = 0; break;
                }
            }
            if ((returned.commonattr & required) != required) {
                printf("BULK_MISSING_COMMON mask=0x%x\n", required & ~returned.commonattr);
                ok = 0; break;
            }
            // The name reference is relative to its own address.
            const unsigned char *ref = p;
            attrreference_t name;
            struct row value = {0};
            if (!take(&p, end, &name, sizeof(name)) ||
                !take(&p, end, &value.device, sizeof(value.device)) ||
                !take(&p, end, &value.type, sizeof(value.type)) ||
                !take(&p, end, &value.modified, sizeof(value.modified)) ||
                !take(&p, end, &value.changed, sizeof(value.changed)) ||
                !take(&p, end, &value.inode, sizeof(value.inode))) { ok = 0; break; }
            if (value.type == REGULAR) {
                if (!(returned.fileattr & ATTR_FILE_DATALENGTH) ||
                    !take(&p, end, &value.size, sizeof(value.size))) {
                    printf("BULK_MISSING_FILE_SIZE\n"); ok = 0; break;
                }
            }
            if (name.attr_dataoffset < 0 || !name.attr_length ||
                (size_t)name.attr_dataoffset > (size_t)(end - ref)) { ok = 0; break; }
            const unsigned char *str = ref + name.attr_dataoffset;
            if (str < p || name.attr_length > (size_t)(end - str) ||
                str[name.attr_length - 1] != 0 ||
                memchr(str, 0, name.attr_length - 1) != NULL ||
                !value.inode || !append(out, value, (const char *)str)) { ok = 0; break; }
            p = end;
        }
    }
    printf("BULK_BATCHES count=%d\n", batches);
    free(buffer);
    close(fd);
    return ok;
}
static int same_time(struct timespec a, struct timespec b) {
    return a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec;
}
// Recursive experiment, still CI-only. Anchor each opened directory, never
// follow symbolic links, reject partial results. A directory size is acquired
// from its open handle because ATTR_FILE_DATALENGTH is for regular files.
static int stable_directory(const struct stat *a, const struct stat *b) {
    return S_ISDIR(b->st_mode) && a->st_dev == b->st_dev &&
        a->st_ino == b->st_ino && a->st_size == b->st_size &&
        same_time(a->st_mtimespec, b->st_mtimespec) &&
        same_time(a->st_ctimespec, b->st_ctimespec);
}
static int same_directory_row(const struct row *r, const struct stat *s) {
    return S_ISDIR(s->st_mode) && r->device == s->st_dev &&
        r->inode == s->st_ino && same_time(r->modified, s->st_mtimespec) &&
        same_time(r->changed, s->st_ctimespec);
}
static int append_path(struct rows *a, struct row value, const char *path) {
    if (a->n >= LIMIT) return 0;
    for (size_t i = 0; i < a->n; i++)
        if (!strcmp(a->v[i].name, path)) return 0;
    value.name = strdup(path);
    if (!value.name) return 0;
    a->v[a->n++] = value;
    return 1;
}
static int recursive(int fd, const char *prefix, int depth, int use_bulk,
                     struct rows *out, int barrier, int *cancelled) {
    if (depth > 32) return 0;
    struct stat before, after;
    if (fstat(fd, &before) || !S_ISDIR(before.st_mode)) return 0;
    struct rows list = {calloc(LIMIT, sizeof(struct row)), 0};
    if (!list.v) return 0;
    int ok = use_bulk ? bulk(fd, &list) : baseline(fd, &list);
    if (ok && barrier && depth == 0) {
        printf("RECURSIVE_BARRIER\n");
        fflush(stdout);
        int cmd = getchar();
        if (cmd != 'G') { *cancelled = 1; ok = 0; }
    }
    for (size_t i = 0; ok && i < list.n; i++) {
        struct row r = list.v[i];
        if (!strcmp(r.name, ".DS_Store") || !strncasecmp(r.name, ".macsync-", 9)) continue;
        char *path = NULL;
        if (asprintf(&path, "%s%s%s", prefix, *prefix ? "/" : "", r.name) < 0) {
            ok = 0; break;
        }
        if (r.device != before.st_dev || !r.inode ||
            (r.type != DIRECTORY && r.type != REGULAR && r.type != SYMLINK)) {
            free(path); ok = 0; break;
        }
        if (r.type == DIRECTORY) {
            int child = openat(fd, r.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            struct stat opened, live;
            if (child < 0 || fstat(child, &opened) || !same_directory_row(&r, &opened)) {
                if (child >= 0) close(child);
                free(path); ok = 0; break;
            }
            r.size = opened.st_size;
            ok = append_path(out, r, path) &&
                recursive(child, path, depth + 1, use_bulk, out, 0, cancelled) &&
                !fstatat(fd, r.name, &live, AT_SYMLINK_NOFOLLOW) &&
                stable_directory(&opened, &live);
            close(child);
        } else {
            ok = append_path(out, r, path);
        }
        free(path);
    }
    if (ok && (fstat(fd, &after) || !stable_directory(&before, &after))) ok = 0;
    dispose(&list);
    return ok;
}
static int tree_scan(const char *path, int use_bulk, struct rows *out,
                     int barrier, int *cancelled) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return 0;
    struct stat original, current;
    int ok = !fstat(fd, &original) &&
        recursive(fd, "", 0, use_bulk, out, barrier, cancelled) &&
        !lstat(path, &current) && stable_directory(&original, &current);
    close(fd);
    if (!ok) {
        // No partial inventory may escape a failed/cancelled scan.
        for (size_t i = 0; i < out->n; i++) free(out->v[i].name);
        out->n = 0;
    }
    return ok;
}
static int tree_main(char **argv) {
    struct rows a = {calloc(LIMIT, sizeof(struct row)), 0};
    struct rows b = {calloc(LIMIT, sizeof(struct row)), 0};
    if (!a.v || !b.v) return 1;
    int cancelled = 0, a_ok = 0, b_ok = 0;
    double start, a_seconds = 0, b_seconds;
    int barrier = !strcmp(argv[3], "barrier");
    if (barrier) {
        b_ok = tree_scan(argv[1], 1, &b, 1, &cancelled);
        printf("TREE_BARRIER_RESULT label=%s accepted=%d rows=%zu cancelled=%d\n",
            argv[2], b_ok, b.n, cancelled);
        dispose(&a); dispose(&b);
        return b_ok ? 0 : 2;
    }
    if (!strcmp(argv[3], "tree-reverse")) {
        start = tick(); b_ok = tree_scan(argv[1], 1, &b, 0, &cancelled); b_seconds = tick() - start;
        start = tick(); a_ok = tree_scan(argv[1], 0, &a, 0, &cancelled); a_seconds = tick() - start;
    } else {
        start = tick(); a_ok = tree_scan(argv[1], 0, &a, 0, &cancelled); a_seconds = tick() - start;
        start = tick(); b_ok = tree_scan(argv[1], 1, &b, 0, &cancelled); b_seconds = tick() - start;
    }
    size_t mismatches = 0, directories = 0;
    for (size_t i = 0; i < a.n; i++) {
        struct row *x = &a.v[i], *y = NULL;
        for (size_t j = 0; j < b.n; j++)
            if (!strcmp(x->name, b.v[j].name)) { y = &b.v[j]; break; }
        if (x->type == DIRECTORY) directories++;
        if (!y || x->type != y->type || x->device != y->device || x->inode != y->inode ||
            (x->type != SYMLINK && x->size != y->size) ||
            !same_time(x->modified, y->modified) || !same_time(x->changed, y->changed))
            mismatches++;
    }
    int equal = a_ok && b_ok && a.n == b.n && !mismatches;
    printf("TREE_RESULT label=%s order=%s baseline_ok=%d bulk_ok=%d baseline=%zu bulk=%zu directories=%zu mismatches=%zu baseline_seconds=%.9f bulk_seconds=%.9f equivalent=%d\n",
           argv[2], argv[3], a_ok, b_ok, a.n, b.n, directories, mismatches, a_seconds, b_seconds, equal);
    dispose(&a); dispose(&b);
    return equal ? 0 : 2;
}

int main(int argc, char **argv) {
    if (argc != 4) return 1;
    if (!strncmp(argv[3], "tree-", 5) || !strcmp(argv[3], "barrier")) return tree_main(argv);
    int fd = open(argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return 1;
    struct rows a = {calloc(LIMIT, sizeof(struct row)), 0};
    struct rows b = {calloc(LIMIT, sizeof(struct row)), 0};
    if (!a.v || !b.v) return 1;
    double start, a_seconds, b_seconds;
    int a_ok, b_ok;
    if (!strcmp(argv[3], "reverse")) {
        start = tick(); b_ok = bulk(fd, &b); b_seconds = tick() - start;
        start = tick(); a_ok = baseline(fd, &a); a_seconds = tick() - start;
    } else {
        start = tick(); a_ok = baseline(fd, &a); a_seconds = tick() - start;
        start = tick(); b_ok = bulk(fd, &b); b_seconds = tick() - start;
    }
    size_t names = 0, type = 0, identity = 0, sizes = 0, modified = 0, changed = 0;
    for (size_t i = 0; i < a.n; i++) {
        struct row *x = &a.v[i], *y = NULL;
        for (size_t j = 0; j < b.n; j++)
            if (!strcmp(x->name, b.v[j].name)) { y = &b.v[j]; break; }
        if (!y) { names++; continue; }
        if (x->type != y->type) type++;
        if (x->device != y->device || x->inode != y->inode) identity++;
        if (x->type == REGULAR && x->size != y->size) sizes++;
        if (!same_time(x->modified, y->modified)) modified++;
        if (!same_time(x->changed, y->changed)) changed++;
    }
    int equivalent = a_ok && b_ok && a.n == b.n && !names && !type &&
        !identity && !sizes && !modified && !changed;
    printf("BULK_RESULT label=%s order=%s baseline_ok=%d bulk_ok=%d baseline=%zu bulk=%zu "
           "name_mismatch=%zu type_mismatch=%zu identity_mismatch=%zu size_mismatch=%zu "
           "mtime_mismatch=%zu ctime_mismatch=%zu baseline_seconds=%.9f bulk_seconds=%.9f equivalent=%d\n",
           argv[2], argv[3], a_ok, b_ok, a.n, b.n, names, type, identity, sizes, modified,
           changed, a_seconds, b_seconds, equivalent);
    dispose(&a); dispose(&b); close(fd);
    // Unsupported or unequal is a measured capability result, not a pass.
    return equivalent ? 0 : 2;
}
