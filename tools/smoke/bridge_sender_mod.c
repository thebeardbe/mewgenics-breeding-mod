/*
 * Throwaway Mewjector mod for tools/smoke: prove the bidirectional bridge.
 * Connects, sends focus 341, and logs any select command the overlay sends back.
 * Uses port 45799 so it never collides with a real overlay on 45780.
 */

#include <windows.h>
#include "mewjector.h"
#include "bridge_client.h"

#define TEST_PORT 45799
#define TEST_FOCUS_KEY 341

static MewjectorAPI mj;

#define SAY(...) \
    do { \
        if (mj.Log) mj.Log("BridgeSender", __VA_ARGS__); \
    } while (0)

static void BridgeLog(const char* message) {
    SAY("%s", message);
}

static void OnSelect(int64_t key) {
    SAY("smoke: received select key=%lld", (long long)key);
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);
        if (!MJ_Require("BridgeSender") || !MJ_Resolve(&mj)) {
            return TRUE;
        }
        SAY("sender mod: starting bridge client on port %d", TEST_PORT);
        bridge_client_start(TEST_PORT, BridgeLog, OnSelect);
        bridge_client_send_key(TEST_FOCUS_KEY);
        SAY("sender mod: queued focus key=%d", TEST_FOCUS_KEY);
        Sleep(4000);   /* let the worker exchange both directions */
    }
    return TRUE;
}
