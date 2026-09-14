/*
 * loader_crt.c - the file-I/O and case-insensitive-compare half of the CRT
 * shim used by the patched Mewjector loader build.
 *
 * Why this file exists: the loader we ship must import only KERNEL32.dll. A
 * zig/mingw build of Mewjector that links the dynamic UCRT imports
 * api-ms-win-crt-* and crashes Mewgenics at launch under Proton (see the
 * rules at the top of build.sh). The loader calls fopen/fgets/fclose and
 * _fileno/_get_osfhandle for its log and the optional Mewtator manifest, and
 * _stricmp in a few comparisons. We provide those over KERNEL32 so
 * `build.sh loader --patched` can link with -nostdlib, exactly as our mod
 * already does.
 *
 * This is not a general CRT. The memory/string half lives in src/crt_shim.c
 * and the formatting half in src/crt_format.c; this file holds only what the
 * loader needs beyond them. It is compiled with -ffreestanding -fno-builtin.
 *
 * The loader includes <stdio.h>/<io.h>, which declare _fileno, _get_osfhandle
 * and _stricmp as __declspec(dllimport), so its calls go through the __imp_*
 * pointers. The shim therefore defines those pointers too, aimed at local
 * functions (kept static so the dllimport declarations do not clash).
 */

#include <stddef.h>
#include <windows.h>

/* Opaque to the loader; only this file ever looks inside. */
typedef struct LoaderFileSlot FILE;

typedef struct LoaderFileSlot
{
    HANDLE handle;
    int    open;
} LoaderFileSlot;

/* The loader opens at most two files at once (the log and the manifest), but
 * a little slack costs nothing. A slot index doubles as the CRT "fd". */
#define LOADER_FILE_SLOTS 8

static LoaderFileSlot g_loaderFiles[LOADER_FILE_SLOTS];

FILE* fopen(const char* path, const char* mode)
{
    DWORD access;
    DWORD disposition;
    HANDLE handle;
    int slot;

    if (!path || !mode)
    {
        return NULL;
    }
    if (mode[0] == 'w')
    {
        access = GENERIC_WRITE;
        disposition = CREATE_ALWAYS;
    }
    else if (mode[0] == 'r')
    {
        access = GENERIC_READ;
        disposition = OPEN_EXISTING;
    }
    else
    {
        return NULL;
    }

    handle = CreateFileA(path, access, FILE_SHARE_READ | FILE_SHARE_WRITE,
                         NULL, disposition, FILE_ATTRIBUTE_NORMAL, NULL);
    if (handle == INVALID_HANDLE_VALUE)
    {
        return NULL;
    }

    for (slot = 0; slot < LOADER_FILE_SLOTS; slot++)
    {
        if (!g_loaderFiles[slot].open)
        {
            g_loaderFiles[slot].handle = handle;
            g_loaderFiles[slot].open = 1;
            return &g_loaderFiles[slot];
        }
    }

    CloseHandle(handle);
    return NULL;
}

char* fgets(char* buffer, int size, FILE* stream)
{
    int used = 0;

    if (!buffer || size <= 1 || !stream || !stream->open)
    {
        return NULL;
    }

    /* One byte per call: the only reader is the small Mewtator manifest, and
     * this keeps the shim free of a buffering layer. */
    while (used < size - 1)
    {
        char character;
        DWORD read = 0;
        if (!ReadFile(stream->handle, &character, 1, &read, NULL) || read == 0)
        {
            break;
        }
        buffer[used++] = character;
        if (character == '\n')
        {
            break;
        }
    }

    if (used == 0)
    {
        return NULL;
    }
    buffer[used] = '\0';
    return buffer;
}

int fclose(FILE* stream)
{
    if (!stream || !stream->open)
    {
        return -1;
    }
    CloseHandle(stream->handle);
    stream->handle = INVALID_HANDLE_VALUE;
    stream->open = 0;
    return 0;
}

static int LoaderFileno(FILE* stream)
{
    int slot = (int)(stream - g_loaderFiles);
    if (!stream || slot < 0 || slot >= LOADER_FILE_SLOTS)
    {
        return -1;
    }
    return slot;
}

static intptr_t LoaderGetOsHandle(int fd)
{
    if (fd < 0 || fd >= LOADER_FILE_SLOTS || !g_loaderFiles[fd].open)
    {
        return (intptr_t)-1;
    }
    return (intptr_t)g_loaderFiles[fd].handle;
}

/* ASCII case folding is enough: the loader only compares file names and the
 * fixed ASCII keys of its own dictionaries. */
static char LoaderLower(char character)
{
    if (character >= 'A' && character <= 'Z')
    {
        return (char)(character - 'A' + 'a');
    }
    return character;
}

static int LoaderStricmp(const char* left, const char* right)
{
    while (*left != '\0' && LoaderLower(*left) == LoaderLower(*right))
    {
        left++;
        right++;
    }
    return (int)(unsigned char)LoaderLower(*left) - (int)(unsigned char)LoaderLower(*right);
}

/* The loader's declarations are dllimport, so its calls load from these
 * pointers. Aim them at the local definitions above. */
int (*const __imp__stricmp)(const char*, const char*) = LoaderStricmp;
int (*const __imp__fileno)(FILE*) = LoaderFileno;
intptr_t (*const __imp__get_osfhandle)(int) = LoaderGetOsHandle;
