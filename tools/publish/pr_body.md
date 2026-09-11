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
[VEH] tid=332 code=0xC0000094 ...
[VEH] null-rgn diag: fault in ntdll.dll+0x1B2C8
<no further output; two threads left in futex wait, no window>
```

A good launch passes the same lines and reaches `First proxy call`.

The VEH is not the suspect: `MjVectoredFilter` always returns
`EXCEPTION_CONTINUE_SEARCH`, and `LogWriteRaw` uses a 0 ms try-lock.

## Changes

- `Chainloader/EnableEPFallback` (default 1, no behaviour change). `0` skips
  `PatchEntryPointFallback()`; mods load on the first `version.dll` proxy call.
  A WARNING names the risk when disabled.
- `Logging=0` now has an effect. It was parsed but never read. The flag is read
  before the log file is opened, so no file and no output are produced. Crash
  reports under `mod_logs/crashes` are separate and still written.
- Booleans go through one `ParseBoolFlag` helper; a blank value keeps the
  default (previously the inline parses disagreed on empty values). One
  existing-key note: a present-but-blank `Enabled=` now keeps the default
  (enabled) instead of disabling the chainloader. `ScanGameDir=` is unchanged
  (blank still means off).

## Evidence

- Patch applies cleanly to `main` at `ccdd681`.
- Built with MSVC per the README; exports unchanged (43 entries).
- Wine harness, same mod and one proxy call in every case:
  - `EnableEPFallback=1, Logging=1`: entry patched, mod loaded, log written
  - `EnableEPFallback=0, Logging=1`: no entry patch, WARNING logged, mod loaded
  - `Logging=0`: no log file created
  - `Logging=` (blank): default 1, log written
  - `EnableEPFallback=` (blank): default 1, entry patched
  - `EnableEPFallback=no, Logging=yes`: fallback skipped, log written
- Reporter tested `EnableEPFallback=0` on the affected machine and launches
  became consistent.

Happy to test a build if that helps. Longer term, #4 (explicit init entry
point) would remove the need for the entry-point patch.
