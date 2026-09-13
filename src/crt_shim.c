/*
 * crt_shim.c — the smallest C runtime that lets vendored MewUI build into this
 * DLL without pulling in a Windows CRT (ucrt / api-ms-win-crt-*).
 *
 * Why this file exists: the mod is linked with `zig cc ... -nostdlib` and may
 * import only KERNEL32.dll. Any build that imports api-ms-win-crt-* crashed
 * Mewgenics at launch under Proton (see build.sh rule 2). MewUI
 * (vendor/upstream/mewui/src/native/mew_ui_api.c) includes <string.h>,
 * <stdio.h>, <stdarg.h> and <stdlib.h> and calls the functions below, so we
 * provide them here. This is not a general CRT and must not grow into one.
 *
 * This file holds the memory, string and heap half:
 *   mem*  — hand-written copies/compares; MewUI uses memset/memcpy/memcmp.
 *   str*  — hand-written strlen/strcmp/strncpy and wcslen for MewUI's
 *           narrow- and wide-string work.
 *   malloc/calloc/free — the process heap (GetProcessHeap/HeapAlloc/HeapFree).
 *
 * The formatting half (snprintf/vsnprintf/_snwprintf) lives in
 * src/crt_format.c, split out so neither file passes the project's size
 * budget. Both are compiled with -ffreestanding -fno-builtin so the compiler
 * cannot fold a hand-written loop into a call to the same function.
 */

#include <stddef.h>
#include <windows.h>

void* memset(void* destination, int value, size_t count)
{
    volatile unsigned char* cursor = (volatile unsigned char*)destination;
    while (count-- != 0)
    {
        *cursor++ = (unsigned char)value;
    }
    return destination;
}

void* memcpy(void* destination, const void* source, size_t count)
{
    unsigned char* out = (unsigned char*)destination;
    const volatile unsigned char* in = (const volatile unsigned char*)source;
    while (count-- != 0)
    {
        *out++ = *in++;
    }
    return destination;
}

int memcmp(const void* left, const void* right, size_t count)
{
    const volatile unsigned char* a = (const volatile unsigned char*)left;
    const volatile unsigned char* b = (const volatile unsigned char*)right;
    while (count-- != 0)
    {
        if (*a != *b)
        {
            return (*a < *b) ? -1 : 1;
        }
        a++;
        b++;
    }
    return 0;
}

size_t strlen(const char* text)
{
    size_t length = 0;
    if (!text)
    {
        return 0;
    }
    while (text[length] != '\0')
    {
        length++;
    }
    return length;
}

int strcmp(const char* left, const char* right)
{
    while (*left != '\0' && *left == *right)
    {
        left++;
        right++;
    }
    return (int)(unsigned char)*left - (int)(unsigned char)*right;
}

char* strncpy(char* destination, const char* source, size_t count)
{
    size_t i = 0;
    if (!destination)
    {
        return destination;
    }
    if (!source)
    {
        if (count != 0) destination[0] = '\0';
        return destination;
    }
    while (i < count && source[i] != '\0')
    {
        destination[i] = source[i];
        i++;
    }
    while (i < count)
    {
        destination[i++] = '\0';
    }
    return destination;
}

size_t wcslen(const wchar_t* text)
{
    size_t length = 0;
    if (!text)
    {
        return 0;
    }
    while (text[length] != L'\0')
    {
        length++;
    }
    return length;
}

void* malloc(size_t size)
{
    /* Keep zero-byte requests distinct so they can still be freed. */
    if (size == 0)
    {
        size = 1;
    }
    return HeapAlloc(GetProcessHeap(), 0, size);
}

void* calloc(size_t count, size_t size)
{
    size_t total;
    void* memory;

    if (count != 0 && size > (size_t)-1 / count)
    {
        return NULL;
    }
    total = count * size;
    memory = malloc(total);
    if (memory)
    {
        memset(memory, 0, total);
    }
    return memory;
}

void free(void* memory)
{
    if (memory)
    {
        HeapFree(GetProcessHeap(), 0, memory);
    }
}
