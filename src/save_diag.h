/*
 * save_diag — one-shot save-path probe (TEMPORARY; delete once the location
 * of the loaded save's path/name is known).
 *
 * The overlay learns the open save from the Linux process table, which Windows
 * does not expose, so it never learns which save the game loaded. Before the
 * mod can send a `save` message, this probe finds the game's own copy of the
 * loaded save's path/name: it dumps the head of the save object and searches
 * the object (and up to a few of its first pointers) for save-looking strings.
 *
 * It only reads memory, runs once, and sends nothing over the bridge. Every
 * game read goes through IsReadableRange (mem_read.h) and refusals are logged.
 */

#ifndef BREEDING_SAVE_DIAG_H
#define BREEDING_SAVE_DIAG_H

#include <windows.h>

/*: Matches Mewjector's MJ_fn_Log: an owner tag, a printf-style format, then
 *  the format's arguments. The caller supplies its own log sink. */
typedef void (__cdecl *save_diag_log_fn)(const char* owner, const char* format, ...);

/*: Run the probe on the first call and never again (one-shot guard inside).
 *  `save_object` is the MewSaveFile::Load `self` pointer; passing NULL logs and
 *  ends. Safe to call on every load. */
void save_diag_run_once(void* save_object, const char* owner, save_diag_log_fn log_fn);

#endif /* BREEDING_SAVE_DIAG_H */
