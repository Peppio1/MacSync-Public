#ifndef MACSYNC_BULK_METADATA_H
#define MACSYNC_BULK_METADATA_H
#include <stdint.h>
typedef struct {
    const char *name;
    uint32_t type;
    uint64_t device, inode;
    int64_t size, mtime_seconds, mtime_nanos, ctime_seconds, ctime_nanos;
} ms_bulk_entry;
typedef int32_t (*ms_bulk_emit)(void *, const ms_bulk_entry *);
// Caller owns the freshly opened directory descriptor. Name valid only during emit.
// 0 complete, -1 unsupported, -2 malformed, -3 stopped, positive filesystem error.
// Discard every emitted entry on ANY failure.
int32_t ms_bulk_read(int32_t fd, void *context, ms_bulk_emit emit);
#endif
