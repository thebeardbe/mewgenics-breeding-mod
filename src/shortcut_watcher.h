/*
 * shortcut_watcher — the always-on in-game raise hotkey.
 *
 * A dedicated thread polls the keyboard and calls raise() once per fresh press
 * of the combination defined in shortcut_watcher.c. It works in every MewUI
 * mode, including mode 0 where MewUI is never started and there is no UI tick.
 *
 * Nothing here touches game state; the caller supplies the current key and the
 * non-blocking raise call. GetAsyncKeyState lives in user32 and this DLL imports
 * only KERNEL32, so it is resolved dynamically; if that fails the watcher logs
 * one line and disables itself.
 */

#ifndef BREEDING_SHORTCUT_WATCHER_H
#define BREEDING_SHORTCUT_WATCHER_H

#include <stdint.h>

/*: Called from the watcher thread with a short English message. */
typedef void (*shortcut_log_fn)(const char* message);

/*: Called on the watcher thread; returns the selected cat key, 0 for none. */
typedef int64_t (*shortcut_key_fn)(void);

/*: Called on the watcher thread with a fresh-press key; must be non-blocking. */
typedef void (*shortcut_raise_fn)(int64_t key);

/*: Start the watcher (idempotent). */
void shortcut_watcher_start(shortcut_log_fn log_fn,
                            shortcut_key_fn current_key,
                            shortcut_raise_fn raise);

#endif /* BREEDING_SHORTCUT_WATCHER_H */
