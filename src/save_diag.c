/*
 * save_diag — one-shot save-path probe. See save_diag.h.
 *
 * TEMPORARY: delete this module (and its call in spike_mod.c) once the game's
 * copy of the loaded save's path/name has been located.
 */

#include <windows.h>
#include <stdint.h>

#include "mem_read.h"
#include "save_diag.h"

#define SAVE_DIAG_SCAN_BYTES 4096
#define SAVE_DIAG_PTR_SCAN_BYTES 512
#define SAVE_DIAG_PTR_TARGET_BYTES 1024
#define SAVE_DIAG_MAX_POINTERS 8
#define SAVE_DIAG_MAX_CANDIDATES 8
#define SAVE_DIAG_STRING_MAX 128
#define SAVE_DIAG_HEX_BYTES 64
/* Printable ASCII: space (0x20) through '~' (0x7E). */
#define SAVE_DIAG_ASCII_MIN 0x20u
#define SAVE_DIAG_ASCII_MAX 0x7Eu

static volatile LONG g_save_diag_done = 0;

static save_diag_log_fn g_log = NULL;
static const char* g_owner = NULL;

/* The caller owns the sink; forward the same owner/format it registered. */
#define SAY(...) \
    do { \
        if (g_log) g_log(g_owner, __VA_ARGS__); \
    } while (0)

static const char* const kSaveDiagTokens[] = { ".sav", "saves", "campaign" };
#define SAVE_DIAG_TOKEN_COUNT \
    ((int)(sizeof kSaveDiagTokens / sizeof kSaveDiagTokens[0]))

/* How many leading bytes of [base, base+size) are readable. The per-byte
 * fallback only runs when the full range is not, so the common case costs one
 * VirtualQuery. */
static size_t DiagReadablePrefix(const unsigned char* base, size_t size) {
    size_t readable = 0;
    if (IsReadableRange(base, size)) return size;
    while (readable < size && IsReadableRange(base + readable, 1)) readable++;
    return readable;
}

/* A printable ASCII character at character index `index`, or -1. width is 1 for
 * a byte string and 2 for a UTF-16LE string (whose high byte must be zero). */
static int DiagAsciiAt(const unsigned char* base, size_t readable, int width,
                       size_t index) {
    size_t offset = index * (size_t)width;
    unsigned int c;
    if (offset + (size_t)width > readable) return -1;
    if (width == 1) {
        c = base[offset];
    } else {
        if (base[offset + 1] != 0) return -1;
        c = base[offset];
    }
    if (c < SAVE_DIAG_ASCII_MIN || c > SAVE_DIAG_ASCII_MAX) return -1;
    return (int)c;
}

static char DiagLower(char c) {
    return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c;
}

/* Is one of the save tokens at character index `index`? Case-insensitive. */
static int DiagTokenAt(const unsigned char* base, size_t readable, int width,
                       size_t index, const char* token) {
    size_t i;
    for (i = 0; token[i]; i++) {
        int c = DiagAsciiAt(base, readable, width, index + i);
        if (c < 0 || DiagLower((char)c) != DiagLower(token[i])) return 0;
    }
    return 1;
}

static void DiagCopyChars(const unsigned char* base, size_t readable, int width,
                          size_t start, size_t end, char* out, int out_size) {
    size_t i;
    int written = 0;
    if (out_size <= 0) return;
    for (i = start; i < end && written < out_size - 1; i++) {
        int c = DiagAsciiAt(base, readable, width, i);
        if (c < 0) break;
        out[written++] = (char)c;
    }
    out[written] = '\0';
}

/* Log every save-looking string in [base, base+readable). width 1 = ASCII,
 * width 2 = UTF-16LE. from_pointer 0 means base is self; 1 means base is the
 * object *self+anchor_offset (the pointer chain is logged). */
static void DiagScanStrings(int from_pointer, size_t anchor_offset,
                            const unsigned char* base, size_t readable, int width,
                            int* found) {
    size_t char_count = readable / (size_t)width;
    size_t index;
    size_t last_end = 0;

    for (index = 0; index < char_count; index++) {
        int token_index;
        int matched = 0;
        size_t start;
        size_t end;
        char text[SAVE_DIAG_STRING_MAX + 1];

        if (index < last_end) continue;
        for (token_index = 0; token_index < SAVE_DIAG_TOKEN_COUNT; token_index++) {
            if (DiagTokenAt(base, readable, width, index, kSaveDiagTokens[token_index])) {
                matched = 1;
                break;
            }
        }
        if (!matched) continue;

        start = index;
        while (start > 0 && (index - start) < SAVE_DIAG_STRING_MAX
                && DiagAsciiAt(base, readable, width, start - 1) >= 0) {
            start--;
        }
        end = index;
        while (end < char_count && (end - start) < SAVE_DIAG_STRING_MAX
                && DiagAsciiAt(base, readable, width, end) >= 0) {
            end++;
        }

        DiagCopyChars(base, readable, width, start, end, text, (int)sizeof text);
        if (from_pointer) {
            SAY("save-load DIAG: candidate %s = *(self+0x%X)+0x%X \"%s\"",
                width == 1 ? "ascii" : "utf16", (unsigned)anchor_offset,
                (unsigned)(start * (size_t)width), text);
        } else {
            SAY("save-load DIAG: candidate %s = self+0x%X \"%s\"",
                width == 1 ? "ascii" : "utf16",
                (unsigned)(start * (size_t)width), text);
        }
        (*found)++;
        last_end = end;
        if (*found >= SAVE_DIAG_MAX_CANDIDATES) return;
    }
}

static void DiagLogHead(const unsigned char* self, size_t readable) {
    static const char kHex[] = "0123456789ABCDEF";
    char hex[SAVE_DIAG_HEX_BYTES * 3 + 1];
    size_t count = readable < SAVE_DIAG_HEX_BYTES ? readable : SAVE_DIAG_HEX_BYTES;
    size_t i;
    int pos = 0;

    for (i = 0; i < count; i++) {
        hex[pos++] = kHex[(self[i] >> 4) & 0xF];
        hex[pos++] = kHex[self[i] & 0xF];
        hex[pos++] = ' ';
    }
    if (pos > 0 && hex[pos - 1] == ' ') pos--;
    hex[pos] = '\0';
    SAY("save-load DIAG: self head[%u]=%s", (unsigned)count, hex);
}

static void DiagScanPointers(const unsigned char* self, size_t readable, int* found) {
    size_t limit = readable < SAVE_DIAG_PTR_SCAN_BYTES ? readable : SAVE_DIAG_PTR_SCAN_BYTES;
    size_t offset;
    int followed = 0;
    int rejected = 0;

    for (offset = 0; offset + 8 <= limit && followed < SAVE_DIAG_MAX_POINTERS
            && *found < SAVE_DIAG_MAX_CANDIDATES; offset += 8) {
        uintptr_t ptr = *(const uintptr_t*)(self + offset);
        size_t target_readable;

        if (ptr == 0) continue;
        if (!IsReadableRange((const void*)ptr, 8)) {
            /* Not a pointer (or not readable); no read is attempted. */
            rejected++;
            continue;
        }
        followed++;
        target_readable = DiagReadablePrefix((const unsigned char*)ptr,
                                             SAVE_DIAG_PTR_TARGET_BYTES);
        if (target_readable == 0) {
            SAY("save-load DIAG: pointer self+0x%X -> %p: read refused",
                (unsigned)offset, (void*)ptr);
            continue;
        }
        SAY("save-load DIAG: following pointer self+0x%X -> %p (%u readable bytes)",
            (unsigned)offset, (void*)ptr, (unsigned)target_readable);
        DiagScanStrings(1, offset, (const unsigned char*)ptr, target_readable, 1, found);
        if (*found < SAVE_DIAG_MAX_CANDIDATES) {
            DiagScanStrings(1, offset, (const unsigned char*)ptr, target_readable, 2, found);
        }
    }
    SAY("save-load DIAG: pointer scan followed %d, rejected %d unreadable slot(s)",
        followed, rejected);
}

static void RunSaveLoadDiagnostic(void* self) {
    const unsigned char* obj = (const unsigned char*)self;
    size_t readable;
    int found = 0;

    SAY("save-load DIAG (TEMPORARY): first Load, self=%p", self);
    if (!self) {
        SAY("save-load DIAG: self is NULL, diagnostic ends");
        return;
    }
    readable = DiagReadablePrefix(obj, SAVE_DIAG_SCAN_BYTES);
    if (readable < SAVE_DIAG_SCAN_BYTES) {
        SAY("save-load DIAG: self scan of 0x%X bytes stopped at +0x%X (read refused)",
            (unsigned)SAVE_DIAG_SCAN_BYTES, (unsigned)readable);
    }
    if (readable == 0) {
        SAY("save-load DIAG: self is not readable, diagnostic ends");
        return;
    }
    DiagLogHead(obj, readable);
    DiagScanStrings(0, 0, obj, readable, 1, &found);
    if (found < SAVE_DIAG_MAX_CANDIDATES) {
        DiagScanStrings(0, 0, obj, readable, 2, &found);
    }
    if (found < SAVE_DIAG_MAX_CANDIDATES) {
        DiagScanPointers(obj, readable, &found);
    }
    SAY("save-load DIAG: done, %d candidate(s) logged", found);
}

void save_diag_run_once(void* save_object, const char* owner, save_diag_log_fn log_fn) {
    /* One-shot guard: only the first caller probes. */
    if (InterlockedCompareExchange(&g_save_diag_done, 1, 0) != 0) return;
    g_owner = owner;
    g_log = log_fn;
    RunSaveLoadDiagnostic(save_object);
}
