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
    if (*p > end || (size_t)(end - *p) < n) return 0;
    memcpy(out, *p, n);
    *p += (n + 3u) & ~3u;
    return *p <= end;
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
int main(int argc, char **argv) {
    if (argc != 4) return 1;
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
