/*
 * bridge_client — send focus requests to the Mewgenics Breeding Overlay.
 *
 * A tiny, CRT-free client: the mod hooks a game function, calls
 * bridge_client_send_key(key), and a background thread does the JSON POST over
 * loopback TCP. Nothing here may block the game thread, so all socket work
 * happens on the worker.
 *
 * Winsock is resolved dynamically (LoadLibraryA + GetProcAddress) so the DLL
 * keeps importing only KERNEL32, matching the rest of the mod. If the overlay
 * is not running the connect simply fails; the request is dropped and the
 * failure is logged once per state change, never on every selection.
 */

#ifndef BREEDING_BRIDGE_CLIENT_H
#define BREEDING_BRIDGE_CLIENT_H

#include <stdint.h>

/*: Called from the worker thread with a short English message. */
typedef void (*bridge_log_fn)(const char* message);

/*: Start the worker. Idempotent; the first call wins. */
void bridge_client_start(int port, bridge_log_fn log_fn);

/*: Queue a cat key for delivery. Non-blocking; safe from any thread. */
void bridge_client_send_key(int64_t key);

#endif /* BREEDING_BRIDGE_CLIENT_H */
