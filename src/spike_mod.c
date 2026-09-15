/*
 * BreedingSpike — probe for the Mewgenics Breeding Overlay bridge.
 *
 * Scope: prove the in-game side of the bridge without touching the save or
 * game state. Hooks:
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
 *   3. The scene-ready update pass at RVA 0x96AC50 (15 stolen bytes). The bridge
 *      worker only records an overlay select request; this hook runs on the game
 *      thread and drains one request per tick, so every game call happens on the
 *      thread the game owns.
 *
 * On a selection the key is logged and sent to the overlay over loopback TCP.
 *
 * Two extra ways to raise the overlay for the current cat, both of which send
 * the same "raise" message: an always-on Ctrl+Shift+B watcher that works with
 * MewUI entirely off (src/shortcut_watcher.c), and, in MewUI mode 2 only, a
 * non-exclusive hook of an existing vanilla CatMenu button.
 *
 * IMPORTANT: no C runtime. The DLL imports only KERNEL32; Winsock and user32's
 * GetAsyncKeyState are resolved with LoadLibraryA. Keep it that way.
 */

#include <windows.h>
#include <stdarg.h>
#include <stdint.h>

#include "mewjector.h"
#include "bridge_client.h"
#include "shortcut_watcher.h"

#define MOD_NAME "BreedingSpike"

/* ── MewUI integration mode (compile-time) ────────────────────────────────
 *   0 (default) MewUI is never started: no MewUI_Start, no MewUI hooks, no UI
 *               tick, no button. The mod is the pre-MewUI build again: the
 *               save-load roster, current-cat bridge, and overlay select/pane.
 *   1           start MewUI and log readiness, but create no button and do no
 *               scene lookup. Isolates whether MewUI by itself faults.
 *   2           start MewUI and hook an existing vanilla House button
 *               non-exclusively. The attempt count is bounded by the candidate
 *               list so a missing node can never flood the log or the frame
 *               budget the way the first mode 2 build did (~94k handled faults).
 * Override the default with -DMEWUI_MODE=N. */
#ifndef MEWUI_MODE
#define MEWUI_MODE 0
#endif
#if (MEWUI_MODE < 0) || (MEWUI_MODE > 2)
#error "MEWUI_MODE must be 0 (off), 1 (bootstrap only), or 2 (bootstrap + button)"
#endif

#if MEWUI_MODE == 0
#define MEWUI_MODE_NAME "off; MewUI never started"
#elif MEWUI_MODE == 1
#define MEWUI_MODE_NAME "bootstrap only; started, no button, no scene lookup"
#else
#define MEWUI_MODE_NAME "full; started, existing-button hook enabled"
#endif

#if MEWUI_MODE >= 1
#include "mew_ui_api.h"
#endif

/* ── game addresses (build id 25143593) ──────────────────────────────────── */
#define RVA_MEWSAVEFILE_LOAD_CATDATA 0x230060u
#define MEWSAVEFILE_LOAD_STOLEN_BYTES 15

#define RVA_SET_CURRENT_CAT 0xEBBA0u
#define RVA_CAT_UI_SETUP 0xE9AC0u
/* The game's own CatMenu click path: rcx = house, rdx = cat. It calls
 * set_current_cat(house, cat, 1) itself and then opens and populates the
 * detail pane. 0x203C80 / 0x203CC5 are internal branches, not callable
 * entries, so they are not used here. */
#define RVA_OPEN_CAT_DETAIL 0xEC7B0u

/* Scene-ready update pass at RVA 0x96AC50 (15 stolen bytes): the game's own
 * per-scene update entry, called on the game thread. MewUI hooks the same site.
 * Draining overlay select requests here keeps the game calls on the game
 * thread instead of the bridge worker. */
#define RVA_SCENE_READY_UPDATE 0x96AC50u
#define SCENE_READY_STOLEN_BYTES 15
/* Lower runs first. A distinct slot from MewUI's own scene-ready hook and from
 * the probe default so the chain log names this hook separately. */
#define SCENE_READY_HOOK_PRIORITY 40
#define SCENE_READY_HOOK_OWNER "BreedingSpike-select"

/* All the plain probes share one priority; it only orders them against other
 * mods hooking the same RVA. */
#define PROBE_HOOK_PRIORITY 20

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

/* The game's own CatMenu click path (house, cat); see RVA_OPEN_CAT_DETAIL.
 * It sets the current cat and opens the detail pane in one call. */
typedef void (__cdecl *fn_open_cat_detail)(void* house, void* cat);
static fn_open_cat_detail g_open_cat_detail = NULL;

/* The scene-ready update trampoline (the next hook in Mewjector's chain). */
typedef void (__fastcall *fn_scene_ready_update)(void* scene_manager);
static fn_scene_ready_update g_orig_scene_ready_update = NULL;

/* The CatMenu controller, cached when the game sets up the cat UI. */
static void* volatile g_house = NULL;

/* The cat key the CatMenu last made current. Read by the raise hook callback
 * and by the Ctrl+Shift+B watcher so either one can ask the overlay to come
 * forward on that cat. Cached in every MewUI mode, including mode 0. */
static volatile LONG64 g_current_cat_key = 0;

/* Prologue byte count for 0xE9AC0: push rbp (2, REX-prefixed) + push rbx/rsi/rdi
 * (3) + push r12/r13/r14/r15 (8) = 13, then lea rbp,[rsp-0x398] (8) = 21. A
 * 15-byte steal lands inside the lea and executes as an illegal instruction. */
#define CAT_UI_SETUP_STOLEN_BYTES 21

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

/* Safe reads: this DLL is built without the C runtime, so SEH (__try/__except)
 * is not reliable here. Validate every game pointer with VirtualQuery before
 * dereferencing it. */
static int IsReadableRange(const void* address, size_t size) {
    const unsigned char* cursor = (const unsigned char*)address;
    const unsigned char* end;

    if (!address || size == 0) return 0;
    end = cursor + size;
    if (end < cursor) return 0;   /* wrap */

    while (cursor < end) {
        MEMORY_BASIC_INFORMATION info;
        const unsigned char* region_end;
        if (VirtualQuery(cursor, &info, sizeof info) == 0) return 0;
        if (info.State != MEM_COMMIT) return 0;
        if (info.Protect & (PAGE_NOACCESS | PAGE_GUARD)) return 0;
        region_end = (const unsigned char*)info.BaseAddress + info.RegionSize;
        if (region_end <= cursor) return 0;
        cursor = region_end;
    }
    return 1;
}

static void NameFromCatData(const unsigned char* cat_data, char* out, int out_size) {
    const unsigned char* name_field;
    const wchar_t* text;
    uint64_t length;
    uint64_t capacity;
    uint64_t chars;

    if (out_size <= 0) return;
    out[0] = '\0';
    if (!cat_data) return;

    name_field = cat_data + CATDATA_NAME_OFFSET;
    if (!IsReadableRange(name_field, 32)) return;

    length = *(const uint64_t*)(name_field + 16);
    capacity = *(const uint64_t*)(name_field + 24);
    text = (capacity > 7) ? *(const wchar_t* const*)name_field
                          : (const wchar_t*)name_field;

    chars = length > NAME_MAX_CHARS ? NAME_MAX_CHARS : length;
    if (!text || !IsReadableRange(text, (size_t)(chars + 1) * sizeof(wchar_t))) return;
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
    if (!cat_data || !IsReadableRange(cat_data, CATDATA_SQLKEY_OFFSET + 8)) {
        SAY("cat key=%lld: cat data not readable", (long long)key);
        return;
    }
    LogCat(key, (const unsigned char*)cat_data);
}

/* ── hook 2: current cat (CatMenu selection) ─────────────────────────────── */

static void __cdecl HookSetCurrentCat(void* house, void* cat, unsigned char flag) {
    int64_t key = 0;

    if (house) g_house = house;

    /* The key is valid before the call; the CatData at +0x8A8 is only filled in
     * by the original, so read that afterwards (it can be garbage before). */
    if (cat && IsReadableRange((const unsigned char*)cat + HOUSE_CAT_KEY_OFFSET, 8)) {
        key = *(const int64_t*)((const unsigned char*)cat + HOUSE_CAT_KEY_OFFSET);
    }

    if (g_orig_set_current_cat) {
        g_orig_set_current_cat(house, cat, flag);
    }

    if (cat) {
        const unsigned char* obj = (const unsigned char*)cat;
        const unsigned char* cat_data = NULL;
        char name[NAME_BUFFER];
        name[0] = '\0';

        if (IsReadableRange(obj + HOUSE_CAT_CATDATA_OFFSET, 8)) {
            cat_data = *(const unsigned char* const*)(obj + HOUSE_CAT_CATDATA_OFFSET);
        }
        if (cat_data && IsReadableRange(cat_data, CATDATA_SQLKEY_OFFSET + 8)) {
            int64_t sql_key = *(const int64_t*)(cat_data + CATDATA_SQLKEY_OFFSET);
            NameFromCatData(cat_data, name, (int)sizeof name);
            SAY("selected cat key=%lld catData=%llX sqlKey=%lld name=\"%s\"",
                (long long)key, (unsigned long long)(uintptr_t)cat_data,
                (long long)sql_key, name);
            if (key <= 0 && sql_key > 0) key = sql_key;
        } else {
            SAY("selected cat key=%lld (no cat data yet)", (long long)key);
        }
        if (key > 0) {
            InterlockedExchange64(&g_current_cat_key, key);
            bridge_client_send_key(key);
        }
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

/* Find the house cat with *key* and make it the CatMenu's current cat, then
 * open that cat's detail pane by calling the game's own click path. Every game
 * pointer is validated first (no SEH in this build). */
static int SelectCatByKey(int64_t key) {
    void* house = g_house;
    unsigned char* holder;
    unsigned char* manager;
    unsigned char* comp_array;
    unsigned char* component;
    unsigned char** data;
    uint32_t count;
    uint32_t i;

    if (!house) {
        SAY("select key=%lld: house not cached yet (no house cat UI?)", (long long)key);
        return 0;
    }
    if (!IsReadableRange((unsigned char*)house + HOUSE_SCENE_HOLDER_OFFSET, 8)) {
        SAY("select key=%lld: house not readable", (long long)key);
        return 0;
    }
    holder = *(unsigned char**)((unsigned char*)house + HOUSE_SCENE_HOLDER_OFFSET);
    if (!holder || !IsReadableRange(holder + HOUSE_SCENE_MANAGER_OFFSET, 8)) {
        SAY("select key=%lld: scene holder not readable", (long long)key);
        return 0;
    }
    manager = *(unsigned char**)(holder + HOUSE_SCENE_MANAGER_OFFSET);
    if (!manager || !IsReadableRange(manager + SCENE_COMPONENT_ARRAY_OFFSET, 8)) {
        SAY("select key=%lld: scene manager not readable", (long long)key);
        return 0;
    }
    comp_array = *(unsigned char**)(manager + SCENE_COMPONENT_ARRAY_OFFSET);
    if (!comp_array || !IsReadableRange(
            comp_array + HOUSE_CATS_COMPONENT_TYPE * COMPONENT_STRIDE, 8)) {
        SAY("select key=%lld: component array not readable", (long long)key);
        return 0;
    }
    component = *(unsigned char**)(comp_array + HOUSE_CATS_COMPONENT_TYPE * COMPONENT_STRIDE);
    if (!component
            || !IsReadableRange(component + COMPONENT_DATA_OFFSET, 8)
            || !IsReadableRange(component + COMPONENT_COUNT_OFFSET, 4)) {
        SAY("select key=%lld: house cat list not found", (long long)key);
        return 0;
    }

    data = *(unsigned char***)(component + COMPONENT_DATA_OFFSET);
    count = *(uint32_t*)(component + COMPONENT_COUNT_OFFSET);
    if (count > 4096) count = 4096;   /* sanity on a hostile/garbage count */
    SAY("select key=%lld: house cat list has %u entries", (long long)key, count);

    for (i = 0; i < count; i++) {
        unsigned char* cat;
        int64_t cat_key;
        if (!data || !IsReadableRange(data + i, 8)) break;
        cat = data[i];
        if (!cat || !IsReadableRange(cat + HOUSE_CAT_KEY_OFFSET, 8)) continue;
        cat_key = *(int64_t*)(cat + HOUSE_CAT_KEY_OFFSET);
        if (cat_key == key) {
            SAY("select key=%lld: found at index %u, applying", (long long)key, i);
            if (g_open_cat_detail
                    && IsReadableRange((const void*)g_open_cat_detail, 1)) {
                SAY("select key=%lld: calling game click path fn=%p house=%p cat=%p",
                    (long long)key, (void*)g_open_cat_detail, house, (void*)cat);
                g_open_cat_detail(house, cat);
                SAY("select key=%lld: game click path returned", (long long)key);
                return 1;
            }
            SAY("select key=%lld: game click path unavailable, falling back to set_current_cat",
                (long long)key);
            if (g_orig_set_current_cat) {
                g_orig_set_current_cat(house, cat, 1);
                return 1;
            }
            break;
        }
    }
    SAY("select key=%lld: key not present in the house cat list", (long long)key);
    return 0;
}

static void OnSelectCommand(int64_t key) {
    SAY("overlay asked to select key=%lld", (long long)key);
    SelectCatByKey(key);
}

/* ── hook 4: drain overlay select requests on the game thread ───────────── */

/* Runs on the game thread at the scene-ready update pass. The bridge worker
 * only records the newest select key; here, once per tick, at most one request
 * is drained and the existing select-and-open work happens on this thread.
 * Chain convention: pass through to the trampoline first, then do our work. */
static void __fastcall HookSceneReady(void* scene_manager) {
    if (g_orig_scene_ready_update) g_orig_scene_ready_update(scene_manager);
    bridge_client_drain_pending_select();
}

/* ── in-game shortcut (all modes, including mode 0) ─────────────────────── */

/* Atomic read: the watcher thread reads the key the game thread cached in
 * HookSetCurrentCat. */
static int64_t CurrentCatKey(void) {
    return (int64_t)InterlockedCompareExchange64(&g_current_cat_key, 0, 0);
}

/* Called from the watcher thread on a fresh Ctrl+Shift+B press. The watcher has
 * already logged and skipped the no-key case, so only a real key arrives. */
static void OnShortcutRaise(int64_t key) {
    SAY("shortcut raise: key=%lld", (long long)key);
    bridge_client_send_raise(key);
}

/* ── init ────────────────────────────────────────────────────────────────── */

static void BridgeLog(const char* message) {
    SAY("%s", message);
}

#if MEWUI_MODE >= 1
/* ── MewUI bootstrap (modes 1 and 2) ────────────────────────────────────── */

/* Lower numbers are called first when several mods hook the same RVA. MewUI
 * only hooks the scene-ready/button RVAs, so this only orders it against other
 * MewUI-style mods, not against our own probes. */
#define MEW_UI_HOOK_PRIORITY 30
/* MewUI retries its hook install on this cadence until Mewjector is ready. */
#define MEW_UI_BOOTSTRAP_INTERVAL_MS 100u
/* Present for the API signature; MewUI drives work from the scene-ready hook. */
#define MEW_UI_TICK_INTERVAL_MS 16u

static volatile LONG g_ui_tick_count = 0;

#if MEWUI_MODE == 2
/* ── existing-button hook (mode 2) ──────────────────────────────────────── */

/* MewUI cannot create new UI from the DLL alone (its own README: a mod must
 * ship an SWF for that), so instead we hook an existing vanilla button
 * non-exclusively: the game's own click still runs, and the click event also
 * queues the raise. The candidates are CatMenu nodes in the House scene
 * (RESEARCH.md section 4). One name is tried per attempt, so at most
 * RAISE_BUTTON_MAX_ATTEMPTS scene lookups happen in total, never per frame. */
#define RAISE_BUTTON_SCENE "House"
#define RAISE_BUTTON_NODE_CANDIDATES { "Stats", "HouseCatStatus", "tobox" }

/* The node may not be up on the first scene-ready tick, so try the candidates a
 * few times and then give up. Between attempts the tick costs two flag tests;
 * the scene lookup happens only inside an attempt. */
#define RAISE_BUTTON_ATTEMPT_INTERVAL_TICKS 60

static const char* const kRaiseButtonNodeCandidates[] = RAISE_BUTTON_NODE_CANDIDATES;
/* One attempt per candidate: three for the three names above. */
#define RAISE_BUTTON_MAX_ATTEMPTS \
    ((int)(sizeof kRaiseButtonNodeCandidates / sizeof kRaiseButtonNodeCandidates[0]))

static void* g_raise_button = NULL;
static int g_raise_button_ready = 0;
static int g_raise_button_attempts = 0;
static int g_raise_button_gave_up = 0;
static LONG g_raise_button_next_attempt_tick = 0;

static void __cdecl OnRaiseButtonEvent(void* button, MewButtonEvent event_type,
                                       MewButtonState old_state, MewButtonState new_state,
                                       void* user_data) {
    int64_t key;
    (void)user_data;

    if (event_type != MEW_BUTTON_EVENT_CLICK) return;

    key = (int64_t)InterlockedCompareExchange64(&g_current_cat_key, 0, 0);
    SAY("raise button clicked: button=%p (%s -> %s) key=%lld", button,
        MewUI_GetButtonStateName(old_state), MewUI_GetButtonStateName(new_state),
        (long long)key);

    if (key <= 0) {
        SAY("raise button: no current cat key, raise request skipped");
        return;
    }
    bridge_client_send_raise(key);
}

/* One bounded attempt: try exactly one candidate name with one non-exclusive
 * hook call. Runs at most RAISE_BUTTON_MAX_ATTEMPTS times, one attempt every
 * RAISE_BUTTON_ATTEMPT_INTERVAL_TICKS scene-ready ticks, then stops for good. */
static void AttemptRaiseButton(LONG tick) {
    const char* node = kRaiseButtonNodeCandidates[g_raise_button_attempts];
    void* button;

    g_raise_button_attempts++;
    SAY("raise button hook: attempt %d/%d scene='%s' node='%s'",
        g_raise_button_attempts, RAISE_BUTTON_MAX_ATTEMPTS,
        RAISE_BUTTON_SCENE, node);

    button = MewUI_HookExistingButtonByNodeName(RAISE_BUTTON_SCENE, node,
                                                OnRaiseButtonEvent, NULL,
                                                &g_raise_button);
    if (!button) {
        g_raise_button = NULL;
        if (g_raise_button_attempts >= RAISE_BUTTON_MAX_ATTEMPTS) {
            g_raise_button_gave_up = 1;
            SAY("raise button hook: all %d candidate nodes in scene='%s' failed; "
                "will not be retried",
                RAISE_BUTTON_MAX_ATTEMPTS, RAISE_BUTTON_SCENE);
            return;
        }
        g_raise_button_next_attempt_tick = tick + RAISE_BUTTON_ATTEMPT_INTERVAL_TICKS;
        SAY("raise button hook: node='%s' not found; next candidate at tick %ld",
            node, (long)g_raise_button_next_attempt_tick);
        return;
    }

    g_raise_button_ready = 1;
    SAY("raise button hook: node='%s' hooked in scene='%s' "
        "(game click kept, raise added) button=%p",
        node, RAISE_BUTTON_SCENE, button);
}
#endif /* MEWUI_MODE == 2 */

/* MewUI calls this from its scene-ready update hook once its own hooks are
 * installed, so the first call is the real "MewUI is ready" signal. In mode 1
 * it only logs that readiness; in mode 2 it also runs the bounded
 * existing-button hook attempts. It never writes game state. */
static void __cdecl OnUiTick(void* user_data) {
    LONG ticks;
    (void)user_data;

    ticks = InterlockedIncrement(&g_ui_tick_count);
    if (ticks == 1) {
        SAY("MewUI ready: first scene-ready UI tick (owner=%s)", MOD_NAME);
        MewUI_LogMessage("BreedingSpike: MewUI ready and ticking");
    }

#if MEWUI_MODE == 2
    /* Cheap gate: once ready or given up this is two flag tests, and the next
     * scene lookup only happens on a scheduled attempt tick. */
    if (!MewUI_IsReady()) return;
    if (g_raise_button_ready || g_raise_button_gave_up) return;
    if (ticks < g_raise_button_next_attempt_tick) return;
    AttemptRaiseButton(ticks);
#endif
}
#endif /* MEWUI_MODE >= 1 */

static void InstallProbe(const char* label, UINT_PTR rva, int stolen,
                         void* hook, void** trampoline_out,
                         int priority, const char* owner) {
    int ok = g_mj.InstallHook(rva, stolen, hook, trampoline_out, priority, owner);
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
        SAY("MewUI mode=%d (%s)", MEWUI_MODE, MEWUI_MODE_NAME);

        if (g_mj.GetGameBase) {
            UINT_PTR base = g_mj.GetGameBase();
            g_open_cat_detail = (fn_open_cat_detail)(base + RVA_OPEN_CAT_DETAIL);
            SAY("open cat detail resolved: base=0x%llX rva=0x%X fn=%p",
                (unsigned long long)base, (unsigned)RVA_OPEN_CAT_DETAIL,
                (void*)g_open_cat_detail);
        } else {
            SAY("open cat detail: GetGameBase unavailable, falling back to set_current_cat");
        }

        InstallProbe("save-load", RVA_MEWSAVEFILE_LOAD_CATDATA,
                     MEWSAVEFILE_LOAD_STOLEN_BYTES, (void*)HookLoadCatData,
                     (void**)&g_orig_load_catdata,
                     PROBE_HOOK_PRIORITY, MOD_NAME);
        InstallProbe("current-cat", RVA_SET_CURRENT_CAT, 0,
                     (void*)HookSetCurrentCat,
                     (void**)&g_orig_set_current_cat,
                     PROBE_HOOK_PRIORITY, MOD_NAME);
        InstallProbe("cat-ui-setup", RVA_CAT_UI_SETUP, CAT_UI_SETUP_STOLEN_BYTES,
                     (void*)HookCatUiSetup,
                     (void**)&g_orig_cat_ui_setup,
                     PROBE_HOOK_PRIORITY, MOD_NAME);
        InstallProbe("scene-ready", RVA_SCENE_READY_UPDATE, SCENE_READY_STOLEN_BYTES,
                     (void*)HookSceneReady,
                     (void**)&g_orig_scene_ready_update,
                     SCENE_READY_HOOK_PRIORITY, SCENE_READY_HOOK_OWNER);

        bridge_client_start(45780, BridgeLog, OnSelectCommand);

        /* Runs in every mode, including mode 0 where MewUI is never started
         * and there is no UI tick. */
        shortcut_watcher_start(BridgeLog, CurrentCatKey, OnShortcutRaise);

#if MEWUI_MODE >= 1
        MewUI_SetDebugLogsEnabled(false);
        if (MewUI_Start(MOD_NAME, MEW_UI_HOOK_PRIORITY, MEW_UI_BOOTSTRAP_INTERVAL_MS,
                        MEW_UI_TICK_INTERVAL_MS, OnUiTick, NULL)) {
            SAY("MewUI bootstrap started (owner=%s, debug logs off)", MOD_NAME);
        } else {
            SAY("MewUI bootstrap failed to start (timer queue unavailable)");
        }
#endif

        if (g_mj.VerifyHooks) {
            SAY("verify hooks -> %d corrupted", g_mj.VerifyHooks());
        }
    }

    return TRUE;
}
