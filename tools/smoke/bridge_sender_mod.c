/*
 * Throwaway Mewjector mod for tools/smoke: prove the CRT-free bridge client
 * reaches a real overlay. It installs no game hooks, so it is safe against the
 * throwaway wintest.exe.
 *
 * Queue key 341 (a real cat in the sample save) and give the worker a moment
 * to deliver it before the host process exits.
 */

#include <windows.h>
#include "mewjector.h"
#include "bridge_client.h"

#define TEST_KEY 341

static MewjectorAPI mj;

#define SAY(...) \
    do { \
        if (mj.Log) mj.Log("BridgeSender", __VA_ARGS__); \
    } while (0)

static void BridgeLog(const char* message) {
    SAY("%s", message);
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        if (!MJ_Require("BridgeSender") || !MJ_Resolve(&mj)) {
            return TRUE;
        }
        SAY("sender mod: starting bridge client");
        bridge_client_start(45780, BridgeLog);
        bridge_client_send_key(TEST_KEY);
        SAY("sender mod: queued key=%d", TEST_KEY);
        Sleep(1500);   /* only valid here: let the worker deliver before exit */
    }
    return TRUE;
}
