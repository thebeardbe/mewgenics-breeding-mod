/*
 * shortcut_watcher implementation — see shortcut_watcher.h.
 *
 * The DLL imports only KERNEL32, so GetAsyncKeyState (user32) is resolved with
 * LoadLibraryA/GetProcAddress. The watcher thread polls it every
 * SHORTCUT_POLL_MS and fires once per fresh press: it remembers whether the
 * combination was held on the previous poll and acts only on a rising edge, so
 * holding the keys down cannot repeat the raise.
 *
 * The thread touches no game state. It reads the key the current-cat hook
 * already cached (an atomic read) and hands it to the bridge client, which only
 * sets a pending value. Every loop iteration is one GetAsyncKeyState per key
 * plus a Sleep.
 */

#include <windows.h>
#include <stdint.h>

#include "shortcut_watcher.h"

/* Shortcut polling cadence. 50 ms feels immediate and costs nothing next to a
 * frame. */
#define SHORTCUT_POLL_MS 50u

/* GetAsyncKeyState sets this bit of the returned SHORT while the key is down. */
#define KEY_DOWN_MASK 0x8000

#define SHORTCUT_COMBO_MAX 48
#define SHORTCUT_MESSAGE_MAX 96

/* The shortcut, in one place: every virtual key listed here must be held for a
 * press to fire, and the names spell the combination for the log. The vk and
 * name of each row sit together so the polled keys and the displayed name (and
 * therefore the arming log line) cannot drift apart. Add or remove an entry to
 * change the combination. */
#define SHORTCUT_KEYS \
    {VK_CONTROL, "Ctrl"}, \
    {VK_SHIFT, "Shift"}, \
    {'B', "B"}

typedef struct ShortcutKey {
    int vk;
    const char* name;
} ShortcutKey;

static const ShortcutKey kShortcutKeys[] = { SHORTCUT_KEYS };
#define SHORTCUT_KEY_COUNT ((int)(sizeof kShortcutKeys / sizeof kShortcutKeys[0]))

typedef SHORT (WINAPI *fn_get_async_key_state)(int vk);

static fn_get_async_key_state g_get_async_key_state = NULL;
static shortcut_log_fn g_log = NULL;
static shortcut_key_fn g_current_key = NULL;
static shortcut_raise_fn g_raise = NULL;
static LONG g_started = 0;

static char g_combo_name[SHORTCUT_COMBO_MAX];
static char g_armed_message[SHORTCUT_MESSAGE_MAX];
static char g_no_key_message[SHORTCUT_MESSAGE_MAX];

static void LogLine(const char* message) {
    if (g_log) g_log(message);
}

/* Append src after pos, never past capacity - 1, and keep it terminated. */
static int AppendText(char* dst, int pos, int capacity, const char* src) {
    while (*src && pos < capacity - 1) dst[pos++] = *src++;
    dst[pos] = '\0';
    return pos;
}

static void BuildMessages(void) {
    int pos;
    int i;

    pos = 0;
    for (i = 0; i < SHORTCUT_KEY_COUNT; i++) {
        if (i > 0) {
            pos = AppendText(g_combo_name, pos, (int)sizeof g_combo_name, "+");
        }
        pos = AppendText(g_combo_name, pos, (int)sizeof g_combo_name,
                         kShortcutKeys[i].name);
    }

    pos = AppendText(g_armed_message, 0, (int)sizeof g_armed_message,
                     "shortcut armed: ");
    AppendText(g_armed_message, pos, (int)sizeof g_armed_message, g_combo_name);

    pos = AppendText(g_no_key_message, 0, (int)sizeof g_no_key_message,
                     "shortcut ");
    pos = AppendText(g_no_key_message, pos, (int)sizeof g_no_key_message,
                     g_combo_name);
    AppendText(g_no_key_message, pos, (int)sizeof g_no_key_message,
               ": no current cat key, raise skipped");
}

/* True only while every key of the combination is held. */
static int ShortcutHeld(void) {
    int i;
    for (i = 0; i < SHORTCUT_KEY_COUNT; i++) {
        if ((g_get_async_key_state(kShortcutKeys[i].vk) & KEY_DOWN_MASK) == 0) {
            return 0;
        }
    }
    return 1;
}

static DWORD WINAPI ShortcutWorker(LPVOID unused) {
    int was_held = 0;
    (void)unused;

    for (;;) {
        int held = ShortcutHeld();
        if (held && !was_held) {
            int64_t key = g_current_key ? g_current_key() : 0;
            if (key > 0) {
                if (g_raise) g_raise(key);
            } else {
                LogLine(g_no_key_message);
            }
        }
        was_held = held;
        Sleep(SHORTCUT_POLL_MS);
    }
    return 0;
}

void shortcut_watcher_start(shortcut_log_fn log_fn, shortcut_key_fn current_key,
                            shortcut_raise_fn raise) {
    HMODULE user32;

    if (InterlockedCompareExchange(&g_started, 1, 0) != 0) return;
    g_log = log_fn;
    g_current_key = current_key;
    g_raise = raise;

    user32 = LoadLibraryA("user32.dll");
    if (user32) {
        g_get_async_key_state =
            (fn_get_async_key_state)GetProcAddress(user32, "GetAsyncKeyState");
    }
    if (!g_get_async_key_state) {
        LogLine("shortcut disabled: GetAsyncKeyState not resolved from user32.dll");
        return;
    }
    LogLine("shortcut: GetAsyncKeyState resolved from user32.dll");

    BuildMessages();
    LogLine(g_armed_message);

    if (!CreateThread(NULL, 0, ShortcutWorker, NULL, 0, NULL)) {
        LogLine("shortcut disabled: watcher thread could not be created");
        g_started = 0;
        return;
    }
}
