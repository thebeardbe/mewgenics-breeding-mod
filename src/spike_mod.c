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
 * SQLite `cats.key` (db_key) is the same integer the game uses, which is the
 * contract the whole bridge depends on.
 *
 * This file is intentionally throwaway. It will be replaced by the real mod.
 */

#include <windows.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>

#include "mewjector.h"

#define MOD_NAME "BreedingSpike"

/* ── game addresses (build id 25143593) ──────────────────────────────────── */
/* glaiel::MewSaveFile::Load(__int64, glaiel::CatData&)
 * Found by cross-referencing the function's assert signature string in the
 * exe. RVA is relative to the module base from MJ_GetGameBase(). */
#define RVA_MEWSAVEFILE_LOAD_CATDATA 0x230060u
#define MEWSAVEFILE_LOAD_STOLEN_BYTES 15

/* CatData layout, from the Custom Stray Framework's reversed struct:
 *   +0x018  WideString name
 *   +0xC48  int64 sqlKey                                                   */
#define CATDATA_NAME_OFFSET 0x018u
#define CATDATA_SQLKEY_OFFSET 0xC48u

/* Cap log spam: a full save can hold hundreds of cats. */
#define CAT_LOG_LIMIT 400

static MewjectorAPI g_mj;

static volatile LONG g_cat_count = 0;
static volatile LONG g_fault_count = 0;

typedef void (__cdecl *fn_load_catdata)(void* self, int64_t key, void* cat_data);
static fn_load_catdata g_orig_load_catdata = NULL;

/* ── logging helpers ─────────────────────────────────────────────────────── */

static void Say(const char* fmt, ...) {
    char buffer[512];
    va_list args;
    if (!g_mj.Log) return;
    va_start(args, fmt);
    vsnprintf(buffer, sizeof buffer, fmt, args);
    va_end(args);
    g_mj.Log(MOD_NAME, "%s", buffer);
}

static void WideToUtf8(const wchar_t* src, uint64_t count, char* out, size_t out_size) {
    out[0] = '\0';
    if (!src || count == 0 || out_size < 2) return;
    if (count > 120) count = 120; /* names are short; clamp hostile values */
    WideCharToMultiByte(CP_UTF8, 0, src, (int)count, out, (int)(out_size - 1), NULL, NULL);
    out[out_size - 1] = '\0';
}

/* ── the probe ───────────────────────────────────────────────────────────── */

static void LogCat(int64_t key, const unsigned char* cat) {
    const unsigned char* name_field = cat + CATDATA_NAME_OFFSET;
    const wchar_t* text;
    uint64_t length = *(const uint64_t*)(name_field + 16);
    uint64_t capacity = *(const uint64_t*)(name_field + 24);
    int64_t sql_key = *(const int64_t*)(cat + CATDATA_SQLKEY_OFFSET);
    char name[256];

    /* <=7 wchar units live inline, otherwise the first qword is a heap pointer */
    text = (capacity > 7) ? *(const wchar_t* const*)name_field
                          : (const wchar_t*)name_field;

    WideToUtf8(text, length, name, sizeof name);
    Say("cat key=%lld sqlKey=%lld name=\"%s\"", (long long)key, (long long)sql_key, name);
}

static void __cdecl HookLoadCatData(void* self, int64_t key, void* cat_data) {
    /* Call the original first: the out-parameter is only filled afterwards. */
    if (g_orig_load_catdata) {
        g_orig_load_catdata(self, key, cat_data);
    }

    if (InterlockedIncrement(&g_cat_count) > CAT_LOG_LIMIT) return;

    if (!cat_data) {
        Say("cat key=%lld (null CatData)", (long long)key);
        return;
    }

    /* Never let a bad pointer take the game down: only our own reads are
     * guarded, the original call above is outside this block. */
    __try {
        LogCat(key, (const unsigned char*)cat_data);
    }
    __except (EXCEPTION_EXECUTE_HANDLER) {
        if (InterlockedIncrement(&g_fault_count) <= 5) {
            Say("cat key=%lld: guarded read faulted, offsets may be wrong for this build",
                (long long)key);
        }
    }
}

/* ── init ────────────────────────────────────────────────────────────────── */

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
        Say("FATAL: InstallHook(0x%X) failed; cat probe disabled", RVA_MEWSAVEFILE_LOAD_CATDATA);
        return;
    }

    g_orig_load_catdata = (fn_load_catdata)trampoline;
    Say("cat probe installed: hook rva=0x%X stolen=%d trampoline=%p",
        RVA_MEWSAVEFILE_LOAD_CATDATA, MEWSAVEFILE_LOAD_STOLEN_BYTES, trampoline);
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

        Say("BreedingSpike loaded: mj version=%d gameBase=0x%llX",
            g_mj.GetVersion ? g_mj.GetVersion() : -1,
            (unsigned long long)(g_mj.GetGameBase ? g_mj.GetGameBase() : 0));

        InstallCatProbe();

        if (g_mj.VerifyHooks) {
            Say("verify hooks -> %d corrupted", g_mj.VerifyHooks());
        }
    }

    return TRUE;
}
