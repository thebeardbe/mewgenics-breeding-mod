/*
 * BreedingSpike — probe for the Mewgenics Breeding Overlay bridge.
 *
 * Scope: prove the in-game side of the bridge without touching the save or
 * game state. Two hooks:
 *
 *   1. glaiel::MewSaveFile::Load(__int64 key, CatData& out) at RVA 0x230060.
 *      Logs the roster (key, sqlKey, name) at save load and proves that the
 *      overlay's db_key is the game's cat key.
 *
 *   2. The "set current cat" function at RVA 0xEBBA0
 *        void set_current_cat(House* house, Cat* cat, bool flag)
 *      called whenever the CatMenu's current cat changes (click or the
 *      next/previous cat buttons). The cat object carries its key at +0x80,
 *      which the game itself passes to its CatDatabase lookup, and its CatData
 *      lands at +0x8A8. This is the id the CatMenu shows, so this hook is where
 *      a "send to the breeding manager" button belongs.
 *
 * On a selection the key is logged and sent to the overlay over loopback TCP.
 *
 * IMPORTANT: no C runtime. The DLL imports only KERNEL32; Winsock is resolved
 * with LoadLibraryA. Keep it that way.
 */

#include <windows.h>
#include <stdarg.h>
#include <stdint.h>

#include "mewjector.h"
#include "bridge_client.h"

#define MOD_NAME "BreedingSpike"

/* ── game addresses (build id 25143593) ──────────────────────────────────── */
#define RVA_MEWSAVEFILE_LOAD_CATDATA 0x230060u
#define MEWSAVEFILE_LOAD_STOLEN_BYTES 15

#define RVA_SET_CURRENT_CAT 0xEBBA0u

/* CatData layout (Custom Stray Framework reversed struct):
 *   +0x018  WideString name
 *   +0xC48  int64 sqlKey                                                    */
#define CATDATA_NAME_OFFSET 0x018u
#define CATDATA_SQLKEY_OFFSET 0xC48u

/* House cat object: the game reads its key at +0x80 and its CatData at +0x8A8
 * (observed in the set-current-cat body). */
#define HOUSE_CAT_KEY_OFFSET 0x080u
#define HOUSE_CAT_CATDATA_OFFSET 0x8A8u

#define CAT_LOG_LIMIT 400
#define NAME_MAX_CHARS 120
#define NAME_BUFFER 256

static MewjectorAPI g_mj;

static volatile LONG g_cat_count = 0;

typedef void (__cdecl *fn_load_catdata)(void* self, int64_t key, void* cat_data);
static fn_load_catdata g_orig_load_catdata = NULL;

typedef void (__cdecl *fn_set_current_cat)(void* house, void* cat, unsigned char flag);
static fn_set_current_cat g_orig_set_current_cat = NULL;

/* Formatting is Mewjector's job; we only pass varargs through. */
#define SAY(...) \
    do { \
        if (g_mj.Log) g_mj.Log(MOD_NAME, __VA_ARGS__); \
    } while (0)

static void WideToUtf8(const wchar_t* src, uint64_t count, char* out, int out_size) {
    int written;
    if (out_size <= 0) return;
    out[0] = '\0';
    if (!src || count == 0) return;
    if (count > NAME_MAX_CHARS) count = NAME_MAX_CHARS;
    written = WideCharToMultiByte(CP_UTF8, 0, src, (int)count, out, out_size - 1, NULL, NULL);
    if (written < 0) written = 0;
    out[written] = '\0';
}

static void NameFromCatData(const unsigned char* cat_data, char* out, int out_size) {
    const unsigned char* name_field;
    const wchar_t* text;
    uint64_t length;
    uint64_t capacity;

    if (out_size <= 0) return;
    out[0] = '\0';
    if (!cat_data) return;

    name_field = cat_data + CATDATA_NAME_OFFSET;
    length = *(const uint64_t*)(name_field + 16);
    capacity = *(const uint64_t*)(name_field + 24);
    text = (capacity > 7) ? *(const wchar_t* const*)name_field
                          : (const wchar_t*)name_field;
    WideToUtf8(text, length, out, out_size);
}

/* ── hook 1: save-load roster ────────────────────────────────────────────── */

static void LogCat(int64_t key, const unsigned char* cat) {
    char name[NAME_BUFFER];
    int64_t sql_key = *(const int64_t*)(cat + CATDATA_SQLKEY_OFFSET);
    NameFromCatData(cat, name, (int)sizeof name);
    SAY("cat key=%lld sqlKey=%lld name=\"%s\"", (long long)key, (long long)sql_key, name);
}

static void __cdecl HookLoadCatData(void* self, int64_t key, void* cat_data) {
    if (g_orig_load_catdata) {
        g_orig_load_catdata(self, key, cat_data);
    }
    if (InterlockedIncrement(&g_cat_count) > CAT_LOG_LIMIT) return;
    if (!cat_data) return;
    __try {
        LogCat(key, (const unsigned char*)cat_data);
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        SAY("cat key=%lld: guarded read faulted", (long long)key);
    }
}

/* ── hook 2: current cat (CatMenu selection) ─────────────────────────────── */

static void __cdecl HookSetCurrentCat(void* house, void* cat, unsigned char flag) {
    if (cat) {
        __try {
            const unsigned char* obj = (const unsigned char*)cat;
            int64_t key = *(const int64_t*)(obj + HOUSE_CAT_KEY_OFFSET);
            const unsigned char* cat_data =
                *(const unsigned char* const*)(obj + HOUSE_CAT_CATDATA_OFFSET);
            int64_t sql_key = cat_data
                ? *(const int64_t*)(cat_data + CATDATA_SQLKEY_OFFSET) : -1;
            char name[NAME_BUFFER];
            NameFromCatData(cat_data, name, (int)sizeof name);

            SAY("selected cat key=%lld catData=%llX sqlKey=%lld name=\"%s\"",
                (long long)key, (unsigned long long)(uintptr_t)cat_data,
                (long long)sql_key, name);

            if (key <= 0 && sql_key > 0) key = sql_key;
            if (key > 0) bridge_client_send_key(key);
        }
        __except (EXCEPTION_EXECUTE_HANDLER) {
            SAY("selected cat: guarded read fault");
        }
    }
    if (g_orig_set_current_cat) {
        g_orig_set_current_cat(house, cat, flag);
    }
}

/* ── init ────────────────────────────────────────────────────────────────── */

static void BridgeLog(const char* message) {
    SAY("%s", message);
}

static void InstallProbe(const char* label, UINT_PTR rva, int stolen,
                         void* hook, void** trampoline_out) {
    int ok = g_mj.InstallHook(rva, stolen, hook, trampoline_out, 20, MOD_NAME);
    if (!ok) {
        SAY("FATAL: InstallHook(%s rva=0x%X) failed; probe disabled", label, (unsigned)rva);
        return;
    }
    SAY("%s probe installed: hook rva=0x%X stolen=%d trampoline=%p",
        label, (unsigned)rva, stolen, *trampoline_out);
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID reserved) {
    (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);

        if (!MJ_Require(MOD_NAME) || !MJ_Resolve(&g_mj)) {
            OutputDebugStringA("BreedingSpike: Mewjector API unavailable\n");
            return TRUE;
        }

        SAY("BreedingSpike loaded: mj version=%d gameBase=0x%llX",
            g_mj.GetVersion ? g_mj.GetVersion() : -1,
            (unsigned long long)(g_mj.GetGameBase ? g_mj.GetGameBase() : 0));

        InstallProbe("save-load", RVA_MEWSAVEFILE_LOAD_CATDATA,
                     MEWSAVEFILE_LOAD_STOLEN_BYTES, (void*)HookLoadCatData,
                     (void**)&g_orig_load_catdata);
        InstallProbe("current-cat", RVA_SET_CURRENT_CAT, 0,
                     (void*)HookSetCurrentCat,
                     (void**)&g_orig_set_current_cat);

        bridge_client_start(45780, BridgeLog);

        if (g_mj.VerifyHooks) {
            SAY("verify hooks -> %d corrupted", g_mj.VerifyHooks());
        }
    }

    return TRUE;
}
