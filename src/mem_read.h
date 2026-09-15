/*
 * mem_read — validate a game pointer before dereferencing it.
 *
 * This DLL is built without the C runtime, so SEH (__try/__except) is not
 * reliable here. Every game pointer is checked with VirtualQuery first. Both
 * the mod's probes and the save-path diagnostic need the check, so it lives
 * here instead of in either caller.
 */

#ifndef BREEDING_MEM_READ_H
#define BREEDING_MEM_READ_H

#include <stddef.h>

/*: 1 when [address, address+size) is committed, readable memory, 0 otherwise.
 *  A NULL address or a zero size is not readable. */
int IsReadableRange(const void* address, size_t size);

#endif /* BREEDING_MEM_READ_H */
