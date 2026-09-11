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
#define RVA_CAT_UI_SETUP 0xE9AC0u

/* House cat list: the scene's component array is at manager+0x20, one entry per
 * type (0x10 bytes each). Type 0x448 is the House cat list: count at +0xc,
 * pointer array at +0x10, entries are cats with their key at +0x80. */
#define HOUSE_SCENE_HOLDER_OFFSET 0x18u
#define HOUSE_SCENE_MANAGER_OFFSET 0x08u
#define SCENE_COMPONENT_ARRAY_OFFSET 0x20u
#define COMPONENT_STRIDE 0x10u
#define HOUSE_CATS_COMPONENT_TYPE 0x448u
#define COMPONENT_COUNT_OFFSET 0x0Cu
#define COMPONENT_DATA_OFFSET 0x10u

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

typedef void (__cdecl *fn_cat_ui_setup)(void* house);
static fn_cat_ui_setup g_orig_cat_ui_setup = NULL;

/* The CatMenu controller, cached when the game sets up the cat UI. */
static void* volatile g_house = NULL;

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
    if (house) g_house = house;
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

/* ── hook 3: cache the house controller, and select a cat on request ─────── */

static void __cdecl HookCatUiSetup(void* house) {
    g_house = house;
    SAY("house cached at UI setup: %llX", (unsigned long long)(uintptr_t)house);
    if (g_orig_cat_ui_setup) {
        g_orig_cat_ui_setup(house);
    }
}

/* Find the house cat with *key* and make it the CatMenu's current cat. */
static int SelectCatByKey(int64_t key) {
    void* house = g_house;
    int found = 0;

    if (!house) {
        SAY("select key=%lld: house not cached yet (no house cat UI?)", (long long)key);
        return 0;
    }

    __try {
        unsigned char* holder = *(unsigned char**)((unsigned char*)house + HOUSE_SCENE_HOLDER_OFFSET);
        unsigned char* manager = holder
            ? *(unsigned char**)(holder + HOUSE_SCENE_MANAGER_OFFSET) : NULL;
        unsigned char* comp_array = manager
            ? *(unsigned char**)(manager + SCENE_COMPONENT_ARRAY_OFFSET) : NULL;
        unsigned char* component = comp_array
            ? *(unsigned char**)(comp_array + HOUSE_CATS_COMPONENT_TYPE * COMPONENT_STRIDE)
            : NULL;
        unsigned char** data;
        uint32_t count;
        uint32_t i;

        if (!component) {
            SAY("select key=%lld: house cat list not found", (long long)key);
            return 0;
        }

        data = *(unsigned char***)(component + COMPONENT_DATA_OFFSET);
        count = *(uint32_t*)(component + COMPONENT_COUNT_OFFSET);
        SAY("select key=%lld: house cat list has %u entries", (long long)key, count);

        for (i = 0; i < count && data; i++) {
            unsigned char* cat = data[i];
            int64_t cat_key;
            if (!cat) continue;
            cat_key = *(int64_t*)(cat + HOUSE_CAT_KEY_OFFSET);
            if (cat_key == key) {
                SAY("select key=%lld: found at index %u, applying", (long long)key, i);
                if (g_orig_set_current_cat) {
                    g_orig_set_current_cat(house, cat, 1);
                    found = 1;
                }
                break;
            }
        }
        if (!found) {
            SAY("select key=%lld: key not present in the house cat list", (long long)key);
        }
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        SAY("select key=%lld: guarded read fault", (long long)key);
        return 0;
    }
    return found;
}

static void OnSelectCommand(int64_t key) {
    SAY("overlay asked to select key=%lld", (long long)key);
    SelectCatByKey(key);
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
        InstallProbe("cat-ui-setup", RVA_CAT_UI_SETUP, 15,
                     (void*)HookCatUiSetup,
                     (void**)&g_orig_cat_ui_setup);

        bridge_client_start(45780, BridgeLog, OnSelectCommand);

        if (g_mj.VerifyHooks) {
            SAY("verify hooks -> %d corrupted", g_mj.VerifyHooks());
        }
    }

    return TRUE;
}
