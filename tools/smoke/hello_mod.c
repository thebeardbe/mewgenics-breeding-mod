/*
 * Minimal Mewjector mod used only by tools/smoke/run_smoke.sh.
 *
 * It resolves the MJ API, allocates a type id pair, registers a name, and logs.
 * It installs no game hooks, so it is safe to run against the throwaway
 * wintest.exe under Wine.
 */

#include <windows.h>
#include <stdio.h>
#include "mewjector.h"

static MewjectorAPI mj;

static void Say(const char* msg) {
    if (mj.Log) mj.Log("SmokeMod", "%s", msg);
    else OutputDebugStringA(msg);
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        char buf[192];
        DisableThreadLibraryCalls(module);
        if (!MJ_Require("SmokeMod") || !MJ_Resolve(&mj)) {
            OutputDebugStringA("SmokeMod: Mewjector API unavailable\n");
            return TRUE;
        }
        Say("SmokeMod: Mewjector API resolved");
        snprintf(buf, sizeof buf,
                 "SmokeMod: version=%d gameBase=0x%llx typePair=0x%llx registerName=%d",
                 mj.GetVersion ? mj.GetVersion() : -1,
                 (unsigned long long)(mj.GetGameBase ? mj.GetGameBase() : 0),
                 (unsigned long long)(mj.AllocTypeIdPair ? mj.AllocTypeIdPair("SmokeMod") : 0),
                 mj.RegisterName ? mj.RegisterName("status", "SmokeProbe", "SmokeMod") : -1);
        Say(buf);
    }
    return TRUE;
}
