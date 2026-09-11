# Upstream report draft: intermittent startup hang under Proton

Target: [githubuser508/mewjector](https://github.com/githubuser508/mewjector)
Version: v3.4 (release `version.dll`, sha256 `ecb11b059d94347eb14f696a80d461c3305a8fc8dcebabe3fe196fadeeb7a3c2`)
Related: open issue #4 "Add optional explicit mod initialization entry point"

## Summary

Loading any mod via Mewjector under Steam Proton occasionally leaves the game
hung at startup, before any mod is loaded, with a deadlocked process (no window,
two threads, both in `futex` wait). Roughly one launch in three on this machine.
Retrying usually works, so the failure is a race.

## Environment

- Mewgenics `1.1.b21239`, `buildid 25143593`
- Steam Proton Experimental, Steam Linux Runtime 4.0, prefix `compatdata/686060`
- Host: NixOS, Hyprland/Wayland (game under Proton/pressure-vessel)
- Launch options: `WINEDLLOVERRIDES="version=n,b" %command%`
- Mewjector v3.4, one mod DLL in `mods/` (a read-only probe that only installs
  hooks; it is not loaded in the failing case)

## Symptom

`mod_logs/chainloader.log` ends inside Mewjector's entry-point fallback, before
the failure. There is no `First proxy call — loading mods` line, so no mod was
loaded.

Good launch (same build, same mod):

```
[EP-fallback] Handler invoked (g_modsLoaded=0).
[EP-fallback] Async mod-loader spawned.
[EP-fallback] Entry point restored; returning to trampoline.
[VEH] tid=316 code=0x40010006 flags=0x0 addr=00006FFFFFBFD947 fatal=0
First proxy call — loading mods (loader lock released)
...
```

Hung launch:

```
[EP-fallback] Handler invoked (g_modsLoaded=0).
[EP-fallback] Async mod-loader spawned.
[EP-fallback] Entry point restored; returning to trampoline.
[VEH] tid=332 code=0xC0000094 flags=0x0 addr=0000000140D64A69 fatal=0
[VEH] tid=332 code=0xC0000005 flags=0x0 addr=00006FFFFFF4B2C8 type=0 va=00000000000008A0 fatal=0
[VEH] null-rgn diag: RIP=00006FFFFFF4B2C8 RCX=00000001001FDBC0 RDX=0000000000000080
[VEH] null-rgn diag: RAX=0000000000000090 RSP=0000000000C2DE20 RBP=0000000000C2DED0
[VEH] null-rgn diag: fault in ntdll.dll+0x1B2C8
[VEH] null-rgn stk[01] Mewgenics.exe+0xEA3850
[VEH] null-rgn stk[03] kernel32.dll+0x11626
[VEH] null-rgn stk[04] Mewgenics.exe+0xD6E917
[VEH] null-rgn stk[06] Mewgenics.exe+0xD40D37
[VEH] null-rgn stk[08] ntdll.dll+0x401BE
<no further output; process left with 2 threads, both in futex wait>
```

A third variant ends right after the recurring startup divide-by-zero:

```
[VEH] tid=328 code=0xC0000094 flags=0x0 addr=0000000140D64A69 fatal=0
<no further output; same 2-thread futex hang>
```

So the hang is not tied to a specific exception code; the VEH lines are just
whatever was logged before the deadlock.

## Analysis

- The VEH is well behaved: `MjVectoredFilter` always returns
  `EXCEPTION_CONTINUE_SEARCH`, and `LogWriteRaw` uses a 0 ms try-lock, so neither
  swallows exceptions nor deadlocks on the log mutex.
- The hang happens on the entry-point fallback path
  (`PatchEntryPointFallback` -> `EntryPointHandler` -> `EpDeferredLoader`), which
  is the code that intentionally works around a startup race: the game's TLS
  callbacks spin on the CRT critical section at `game+0x13A8268` until
  `mainCRTStartup` initialises it, with 1 MB stacks.
- Under Proton this race still fires intermittently even with the deferred
  loader, so the entry-point patch is the prime suspect.
- `Logging=0` in `chainloader.ini` is parsed into `g_config.logging` but never
  read, so it cannot be used to disable logging. Minor, separate from the hang.

## Suggested directions

1. Implement #4: an explicit opt-in init entry point so the entry patch is not
   needed when a mod (or Mewtator) can trigger loading.
2. Or make the entry-point fallback opt-out via `chainloader.ini`
   (e.g. `EnableEPFallback=0`), so users who only need proxy-export loading can
   avoid the patch entirely.
3. Honour `Logging=0` in `CLog`/`LogWriteRaw`.
4. Optionally reduce work inside the VEH for near-null access violations at
   startup (module enumeration + a 96-slot stack walk happens on the faulting
   thread).

## Offer

Happy to test patched builds on this machine and report back. We can also
provide a repeated-launch harness log showing the good and hung cases side by
side.

## Extra context

The consuming project is a Mewgenics breeding overlay bridge (mod side:
`mewgenics-breeding-mod`). The mod only installs read-only hooks and does no
work in the failing case, so the hang is reproducible independently of it.
