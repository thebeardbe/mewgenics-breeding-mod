/*
 * BreedingSpike — M0 probe for the Mewgenics Breeding Overlay bridge.
 *
 * Scope: prove that a Mewjector mod DLL loads in the real game and that we can
 * read a cat's identity from live game memory. Nothing here touches the save,
 * writes game state, or draws UI.
 *
 * What it does:
 *   1. Resolves the Mewjector API and logs a banner.
 *   2. Hooks glaiel::MewSaveFile::Load(__int64 key, glaiel::CatData& out) and
 *      logs each loaded cat's key, its CatData.sqlKey, and its name.
 *
 * Why this hook: the binary at RVA 0x230101 executes `mov [rsi+0xC48], rdi`,
 * i.e. it stores the load key into CatData.sqlKey. That proves the overlay's
 * SQLite `cats.key` (db_key) is the same integer the game uses.
 *
 * IMPORTANT: this file deliberately uses no C runtime. A DLL that imports
 * `api-ms-win-crt-*` fails to load under Proton's Wine and takes the game down.
 * All formatting is delegated to Mewjector's `MJ_Log` (the official loader is
 * KERNEL32-only and links its own CRT statically). Keep it CRT-free.
 *
 * This file is intentionally throwaway. It will be replaced by the real mod.
 */

#include <windows.h>
#include <stdint.h>

#include "mewjector.h"
#include "bridge_client.h"

#define MOD_NAME "BreedingSpike"

/* ── game addresses (build id 25143593) ──────────────────────────────────── */
#define RVA_MEWSAVEFILE_LOAD_CATDATA 0x230060u
#define MEWSAVEFILE_LOAD_STOLEN_BYTES 15

/* CatData layout (Custom Stray Framework reversed struct):
 *   +0x018  WideString name
 *   +0xC48  int64 sqlKey                                                    */
#define CATDATA_NAME_OFFSET 0x018u
#define CATDATA_SQLKEY_OFFSET 0xC48u

#define CAT_LOG_LIMIT 400
#define NAME_MAX_CHARS 120
#define NAME_BUFFER 256

static MewjectorAPI g_mj;

static volatile LONG g_cat_count = 0;
static volatile LONG g_fault_count = 0;

typedef void (__cdecl *fn_load_catdata)(void* self, int64_t key, void* cat_data);
static fn_load_catdata g_orig_load_catdata = NULL;

/* Formatting is Mewjector's job; we only pass varargs through. */
#define SAY(...) \
    do { \
        if (g_mj.Log) g_mj.Log(MOD_NAME, __VA_ARGS__); \
    } while (0)

/* ── the probe ───────────────────────────────────────────────────────────── */

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

static void LogCat(int64_t key, const unsigned char* cat) {
    const unsigned char* name_field = cat + CATDATA_NAME_OFFSET;
    const wchar_t* text;
    uint64_t length = *(const uint64_t*)(name_field + 16);
    uint64_t capacity = *(const uint64_t*)(name_field + 24);
    int64_t sql_key = *(const int64_t*)(cat + CATDATA_SQLKEY_OFFSET);
    char name[NAME_BUFFER];

    /* <=7 wchar units live inline, otherwise the first qword is a heap pointer */
    text = (capacity > 7) ? *(const wchar_t* const*)name_field
                          : (const wchar_t*)name_field;

    WideToUtf8(text, length, name, (int)sizeof name);
    SAY("cat key=%lld sqlKey=%lld name=\"%s\"", (long long)key, (long long)sql_key, name);
}

static void __cdecl HookLoadCatData(void* self, int64_t key, void* cat_data) {
    /* Call the original first: the out-parameter is only filled afterwards. */
    if (g_orig_load_catdata) {
        g_orig_load_catdata(self, key, cat_data);
    }

    if (InterlockedIncrement(&g_cat_count) > CAT_LOG_LIMIT) return;

    if (!cat_data) {
        SAY("cat key=%lld (null CatData)", (long long)key);
        return;
    }

    /* Never let a bad pointer take the game down: only our own reads are
     * guarded, the original call above is outside this block. */
    __try {
        LogCat(key, (const unsigned char*)cat_data);
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        if (InterlockedIncrement(&g_fault_count) <= 5) {
            SAY("cat key=%lld: guarded read faulted, offsets may be wrong for this build",
                (long long)key);
        }
    }
}

/* ── init ────────────────────────────────────────────────────────────────── */

static void BridgeLog(const char* message) {
    SAY("%s", message);
}

static void InstallCatProbe(void) {
    void* trampoline = NULL;
    int ok;

    ok = g_mj.InstallHook(
        RVA_MEWSAVEFILE_LOAD_CATDATA,
        MEWSAVEFILE_LOAD_STOLEN_BYTES,
        (void*)HookLoadCatData,
        &trampoline,
        20, /* core-mod priority band */
        MOD_NAME);

    if (!ok) {
        SAY("FATAL: InstallHook(0x%X) failed; cat probe disabled", RVA_MEWSAVEFILE_LOAD_CATDATA);
        return;
    }

    g_orig_load_catdata = (fn_load_catdata)trampoline;
    SAY("cat probe installed: hook rva=0x%X stolen=%d trampoline=%p",
        RVA_MEWSAVEFILE_LOAD_CATDATA, MEWSAVEFILE_LOAD_STOLEN_BYTES, trampoline);
}

/* ── selection probe ─────────────────────────────────────────────────────────
 * glaiel::CatSelector::init(__int64 key): the game initialises a cat selector
 * with the cat's key when the player opens a cat (the nametag click path ends
 * up here). RVA from the function's assert signature. The prologue keeps the
 * key in r15 and its shadow-space reads stay consistent under Mewjector's
 * trampoline, same shape as the MewSaveFile::Load hook above. */
#define RVA_CATSELECTOR_INIT 0xDE040u
#define CATSELECTOR_INIT_STOLEN_BYTES 15

typedef void (__cdecl *fn_catsel_init)(void* self, int64_t key);
static fn_catsel_init g_orig_catsel_init = NULL;

static void __cdecl HookCatSelectorInit(void* self, int64_t key) {
    SAY("catselector init key=%lld", (long long)key);
    bridge_client_send_key(key);
    if (g_orig_catsel_init) {
        g_orig_catsel_init(self, key);
    }
}

static void InstallCatSelectorProbe(void) {
    void* trampoline = NULL;
    int ok;

    ok = g_mj.InstallHook(
        RVA_CATSELECTOR_INIT,
        CATSELECTOR_INIT_STOLEN_BYTES,
        (void*)HookCatSelectorInit,
        &trampoline,
        20,
        MOD_NAME);

    if (!ok) {
        SAY("FATAL: InstallHook(0x%X) failed; selection probe disabled",
            RVA_CATSELECTOR_INIT);
        return;
    }

    g_orig_catsel_init = (fn_catsel_init)trampoline;
    SAY("selection probe installed: hook rva=0x%X stolen=%d",
        RVA_CATSELECTOR_INIT, CATSELECTOR_INIT_STOLEN_BYTES);
}

/* ── discovery probe: nametag click ───────────────────────────────────────────
 * house.swf's `nametag_button` is bound to a callback object; its invoke at RVA
 * 0xEDCA0 runs when the player clicks a cat's nametag. That object holds two
 * captured pointers, and the handler forwards *(capture1+0x20) into the cat
 * menu path (0x14074E6C0). We do not yet know which of those points at the
 * cat, so this logs candidate fields and lets one click identify it. Every read
 * is guarded. */
#define RVA_NAMETAG_CLICK 0xEDCA0u

typedef void (__cdecl *fn_nametag_click)(void* callback_obj);
static fn_nametag_click g_orig_nametag_click = NULL;

static void ProbeCandidate(const char* label, const unsigned char* p) {
    if (!p) {
        SAY("  %s = null", label);
        return;
    }
    __try {
        SAY("  %s = %llX: [+0x18]=%llX [+0x20]=%llX [+0xC48]=%lld [+0x8A8]=%llX",
            label,
            (unsigned long long)(uintptr_t)p,
            (unsigned long long)*(const uint64_t*)(p + 0x18),
            (unsigned long long)*(const uint64_t*)(p + 0x20),
            (long long)*(const int64_t*)(p + 0xC48),
            (unsigned long long)*(const uint64_t*)(p + 0x8A8));
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        SAY("  %s = %llX: read fault", label, (unsigned long long)(uintptr_t)p);
    }
}

static void __cdecl HookNametagClick(void* callback_obj) {
    unsigned char* obj = (unsigned char*)callback_obj;
    void* capture1 = NULL;
    void* capture2 = NULL;
    void* target = NULL;

    SAY("nametag click obj=%llX", (unsigned long long)(uintptr_t)obj);

    __try {
        if (obj) {
            capture1 = *(void**)(obj + 0x8);
            capture2 = *(void**)(obj + 0x10);
        }
        if (capture1) {
            target = *(void**)((unsigned char*)capture1 + 0x20);
        }
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        SAY("  nametag header read fault");
    }

    ProbeCandidate("obj", obj);
    ProbeCandidate("capture1", (const unsigned char*)capture1);
    ProbeCandidate("capture2", (const unsigned char*)capture2);
    ProbeCandidate("target", (const unsigned char*)target);

    if (target) {
        __try {
            void* catdata = *(void**)((unsigned char*)target + 0x8A8);
            ProbeCandidate("target+0x8A8", (const unsigned char*)catdata);
        }
        __except (EXCEPTION_EXECUTE_HANDLER) {
            SAY("  target+0x8A8 read fault");
        }
    }

    if (g_orig_nametag_click) {
        g_orig_nametag_click(callback_obj);
    }
}

static void InstallNametagProbe(void) {
    void* trampoline = NULL;
    int ok;

    /* stolenBytes 0: Mewjector decodes the prologue (push rsi / sub rsp,0x20 /
     * mov rax,[rcx+8] / mov rsi,rcx / mov byte [rax+0x71],1 == 16 bytes). */
    ok = g_mj.InstallHook(
        RVA_NAMETAG_CLICK,
        0,
        (void*)HookNametagClick,
        &trampoline,
        20,
        MOD_NAME);

    if (!ok) {
        SAY("FATAL: InstallHook(0x%X) failed; nametag probe disabled",
            RVA_NAMETAG_CLICK);
        return;
    }

    g_orig_nametag_click = (fn_nametag_click)trampoline;
    SAY("nametag probe installed: hook rva=0x%X", RVA_NAMETAG_CLICK);
}

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID reserved) {
    (void)reserved;
    (void)module;

    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(module);

        if (!MJ_Require(MOD_NAME) || !MJ_Resolve(&g_mj)) {
            OutputDebugStringA("BreedingSpike: Mewjector API unavailable\n");
            return TRUE;
        }

        SAY("BreedingSpike loaded: mj version=%d gameBase=0x%llX",
            g_mj.GetVersion ? g_mj.GetVersion() : -1,
            (unsigned long long)(g_mj.GetGameBase ? g_mj.GetGameBase() : 0));

        InstallCatProbe();
        bridge_client_start(45780, BridgeLog);
        InstallCatSelectorProbe();
        InstallNametagProbe();

        if (g_mj.VerifyHooks) {
            SAY("verify hooks -> %d corrupted", g_mj.VerifyHooks());
        }
    }

    return TRUE;
}
