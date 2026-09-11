Loading mods through Mewjector occasionally hangs the game at startup under
Steam Proton, before any mod loads. Roughly one launch in three here; retrying
usually works, so it is a race.

Environment: Mewgenics 1.1.b21239 (buildid 25143593), Proton Experimental,
Steam Linux Runtime 4.0, `WINEDLLOVERRIDES="version=n,b"`, Mewjector v3.4.

The log ends inside the entry-point fallback path, with no
`First proxy call — loading mods` line:

```
[EP-fallback] Handler invoked (g_modsLoaded=0).
[EP-fallback] Async mod-loader spawned.
[EP-fallback] Entry point restored; returning to trampoline.
[VEH] tid=332 code=0xC0000094 flags=0x0 addr=0000000140D64A69 fatal=0
[VEH] tid=332 code=0xC0000005 flags=0x0 addr=00006FFFFFF4B2C8 type=0 va=00000000000008A0 fatal=0
[VEH] null-rgn diag: fault in ntdll.dll+0x1B2C8
[VEH] null-rgn stk[01] Mewgenics.exe+0xEA3850
<no further output; two threads left in futex wait, no window>
```

A good launch passes the same lines and reaches `First proxy call`.

The VEH is not the suspect: `MjVectoredFilter` always returns
`EXCEPTION_CONTINUE_SEARCH`, and `LogWriteRaw` uses a 0 ms try-lock, so it
neither swallows exceptions nor deadlocks on the log mutex.

Two things worth fixing regardless:

- `Logging=0` in `chainloader.ini` is parsed into `g_config.logging` but never
  read, so it cannot be used to silence output.
- The entry-point fallback has no opt-out, so users hitting this race have no
  way to avoid the patch.

Suggested directions: an ini opt-out for the entry-point fallback, honour
`Logging=0`, and longer term the explicit init entry point in #4, which would
remove the need for the patch entirely.

A patch for the first two is attached as a PR: `EnableEPFallback` (default 1)
and a `Logging=0` that creates no file and writes nothing (crash reports under
`mod_logs/crashes` remain separate). Verified: with `EnableEPFallback=0` and no
entry patch, mods still load on the first `version.dll` proxy call.
