#include "MacSyncBulkMetadata.h"
#include <sys/attr.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
enum { BUFFER_BYTES = 65536, REGULAR = 1, DIRECTORY = 2, SYMLINK = 5 };
static int take(const unsigned char **p, const unsigned char *end, void *out, size_t n) {
    size_t aligned = (n + 3u) & ~(size_t)3u;
    if (*p > end || (size_t)(end - *p) < aligned) return 0;
    memcpy(out, *p, n); *p += aligned; return 1;
}
int32_t ms_bulk_read(int32_t fd, void *context, ms_bulk_emit emit) {
    if (!emit) return -2;
    unsigned char *buffer = malloc(BUFFER_BYTES);
    if (!buffer) return ENOMEM;
    struct attrlist attrs = {0};
    attrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    const attrgroup_t required = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME |
        ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME | ATTR_CMN_FILEID;
    attrs.commonattr = required | ATTR_CMN_ERROR;
    attrs.fileattr = ATTR_FILE_DATALENGTH;
    int32_t status = 0;
    while (!status) {
        int n = getattrlistbulk(fd, &attrs, buffer, BUFFER_BYTES, 0);
        if (n < 0) {
            int code = errno;
            status = (code == ENOTSUP || code == ENOSYS) ? -1 : (code ? code : EIO);
            break;
        }
        if (!n) break;
        const unsigned char *p = buffer, *limit = buffer + BUFFER_BYTES;
        for (int i = 0; i < n; i++) {
            const unsigned char *start = p;
            uint32_t length;
            if (!take(&p, limit, &length, sizeof(length)) ||
                length < sizeof(length) + sizeof(attribute_set_t) ||
                length > (size_t)(limit - start)) { status = -2; break; }
            const unsigned char *end = start + length;
            attribute_set_t returned;
            if (!take(&p, end, &returned, sizeof(returned))) { status = -2; break; }
            if (returned.commonattr & ATTR_CMN_ERROR) {
                uint32_t code;
                if (!take(&p, end, &code, sizeof(code))) { status = -2; break; }
                if (code) { status = EIO; break; }
            }
            if ((returned.commonattr & required) != required ||
                (returned.commonattr & ~(required | ATTR_CMN_ERROR)) ||
                returned.volattr || returned.dirattr || returned.forkattr ||
                (returned.fileattr & ~ATTR_FILE_DATALENGTH)) { status = -2; break; }
            const unsigned char *ref = p;
            attrreference_t name;
            dev_t device;
            struct timespec modified, changed;
            ms_bulk_entry entry = {0};
            if (!take(&p, end, &name, sizeof(name)) ||
                !take(&p, end, &device, sizeof(device)) ||
                !take(&p, end, &entry.type, sizeof(entry.type)) ||
                !take(&p, end, &modified, sizeof(modified)) ||
                !take(&p, end, &changed, sizeof(changed)) ||
                !take(&p, end, &entry.inode, sizeof(entry.inode))) { status = -2; break; }
            if (entry.type != REGULAR && entry.type != DIRECTORY && entry.type != SYMLINK) {
                status = -2; break;
            }
            if (returned.fileattr & ATTR_FILE_DATALENGTH) {
                if (!take(&p, end, &entry.size, sizeof(entry.size))) { status = -2; break; }
            } else if (entry.type == REGULAR) { status = -2; break; }
            if (!entry.inode || (entry.type == REGULAR && entry.size < 0) ||
                modified.tv_nsec < 0 || modified.tv_nsec >= 1000000000 ||
                changed.tv_nsec < 0 || changed.tv_nsec >= 1000000000 ||
                name.attr_dataoffset < 0 || !name.attr_length ||
                (size_t)name.attr_dataoffset > (size_t)(end - ref)) { status = -2; break; }
            const unsigned char *str = ref + name.attr_dataoffset;
            if (str < p || name.attr_length > (size_t)(end - str) ||
                str[name.attr_length - 1] != 0 ||
                memchr(str, 0, name.attr_length - 1) != NULL ||
                !str[0] || strchr((const char *)str, '/') ||
                !strcmp((const char *)str, ".") || !strcmp((const char *)str, "..")) {
                status = -2; break;
            }
            entry.name = (const char *)str;
            entry.device = (uint64_t)(int64_t)device;
            entry.mtime_seconds = modified.tv_sec; entry.mtime_nanos = modified.tv_nsec;
            entry.ctime_seconds = changed.tv_sec; entry.ctime_nanos = changed.tv_nsec;
            if (emit(context, &entry)) { status = -3; break; }
            p = end;
        }
    }
    free(buffer);
    return status;
}
