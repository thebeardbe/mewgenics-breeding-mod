/*
 * bridge_client — talk to the Mewgenics Breeding Overlay over loopback TCP.
 *
 * Bidirectional, one persistent connection:
 *   mod -> overlay   {"v":1,"type":"focus","key":341}\n   (a cat was selected)
 *   mod -> overlay   {"v":1,"type":"raise","key":341}\n   (the in-game MBO button was clicked;
 *                                                     focus plus pull to front)
 *   overlay -> mod   {"v":1,"type":"select","key":341}\n  (show this cat in game)
 *
 * A single worker thread owns the socket. It only ever records a pending key,
 * so nothing here can stall a frame; the game thread drains a queued select on
 * its own scene-ready tick (bridge_client_drain_pending_select). Winsock is
 * resolved dynamically so the DLL keeps importing only KERNEL32.
 */

#ifndef BREEDING_BRIDGE_CLIENT_H
#define BREEDING_BRIDGE_CLIENT_H

#include <stdint.h>

/*: Called from the worker thread with a short English message. */
typedef void (*bridge_log_fn)(const char* message);

/*: Called from the game thread when a queued select is drained. */
typedef void (*bridge_select_fn)(int64_t key);

/*: Start the worker (idempotent). */
void bridge_client_start(int port, bridge_log_fn log_fn, bridge_select_fn on_select);

/*: Drain at most one pending overlay select on the calling (game) thread, and
 *  hand it to the select callback. Returns 1 when a request was consumed, 0
 *  when none was pending. A newer request that arrived while one was pending
 *  replaces it, so the newest click wins. */
int bridge_client_drain_pending_select(void);

/*: Queue "this cat is selected" for delivery. Non-blocking. */
void bridge_client_send_key(int64_t key);

/*: Queue "bring the overlay forward for this cat" for delivery. Non-blocking. */
void bridge_client_send_raise(int64_t key);

#endif /* BREEDING_BRIDGE_CLIENT_H */
