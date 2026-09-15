/*
 * mem_read — validate a game pointer before dereferencing it. See mem_read.h.
 */

#include <windows.h>

#include "mem_read.h"

int IsReadableRange(const void* address, size_t size) {
    const unsigned char* cursor = (const unsigned char*)address;
    const unsigned char* end;

    if (!address || size == 0) return 0;
    end = cursor + size;
    if (end < cursor) return 0;   /* wrap */

    while (cursor < end) {
        MEMORY_BASIC_INFORMATION info;
        const unsigned char* region_end;
        if (VirtualQuery(cursor, &info, sizeof info) == 0) return 0;
        if (info.State != MEM_COMMIT) return 0;
        if (info.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
        region_end = (const unsigned char*)info.BaseAddress + info.RegionSize;
        if (region_end <= cursor) return 0;
        cursor = region_end;
    }
    return 1;
}
