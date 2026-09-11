/*
 * Minimal Mewjector mod used only by tools/smoke/run_smoke.sh.
 *
 * Resolves the MJ API, allocates a type id pair, registers a name, and logs.
 * Installs no game hooks, so it is safe against the throwaway wintest.exe.
 *
 * Like src/spike_mod.c it stays CRT-free on purpose: a mod DLL that imports
 * `api-ms-win-crt-*` will not load under Proton's Wine.
 */

#include <windows.h>
#include "mewjector.h"

static MewjectorAPI mj;

#define SAY(...) \
    do { \
        if (mj.Log) mj.Log("SmokeMod", __VA_ARGS__); \
    } while (0)

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        if (!MJ_Require("SmokeMod") || !MJ_Resolve(&mj)) {
            OutputDebugStringA("SmokeMod: Mewjector API unavailable\n");
            return TRUE;
        }
        SAY("SmokeMod: Mewjector API resolved");
        SAY("SmokeMod: version=%d gameBase=0x%llX typePair=0x%llX registerName=%d",
            mj.GetVersion ? mj.GetVersion() : -1,
            (unsigned long long)(mj.GetGameBase ? mj.GetGameBase() : 0),
            (unsigned long long)(mj.AllocTypeIdPair ? mj.AllocTypeIdPair("SmokeMod") : 0),
            mj.RegisterName ? mj.RegisterName("status", "SmokeProbe", "SmokeMod") : -1);
    }
    return TRUE;
}
