/*
 * Throwaway host exe for the Wine smoke test.
 *
 * The game imports VERSION.dll, so the loader proxy only runs when something
 * calls an exported function. This exe calls one to trigger Mewjector's
 * "first proxy call" mod-loading path.
 */

#include <windows.h>
#include <stdio.h>

int main(void) {
    DWORD size = GetFileVersionInfoSizeW(L"Mewgenics.exe", NULL);
    printf("proxy call GetFileVersionInfoSizeW -> %lu\n", (unsigned long)size);
    return 0;
}
