# PR kit: Mewjector `EnableEPFallback` opt-out + honour `Logging=0`

Everything here is ready. Nothing has been posted anywhere.

- Upstream: `githubuser508/mewjector`, default branch `main`
- Verified base: `ccdd681` (upstream `main` at the time of writing)
- Patch: `patches/mewjector-epfallback-and-logging.patch` (one commit)
- Issue text: `docs/upstream-mewjector-startup-hang.md`

## What the change does

1. **`Chainloader/EnableEPFallback`** (default `1`, unchanged behaviour). Set to
   `0` to skip `PatchEntryPointFallback()`. Mods then load on the game's first
   `version.dll` proxy call, which avoids the entry-point patch race that
   intermittently hangs startup under Proton. Setting it to `0` logs a WARNING
   naming the risk: if the game never calls a `version.dll` export, no mods load.
2. **`Logging=0` now works.** It was parsed into `g_config.logging` but never
   read. The flag is now read before the log file is opened, so `Logging=0`
   creates no log file and writes no log output. Crash reports under
   `mod_logs/crashes` are separate and are still written.
3. **Boolean ini values are parsed consistently.** A small `ParseBoolFlag`
   helper is shared by `Enabled`, `Logging`, `EnableEPFallback` and
   `ScanGameDir`. Values accept `1/y/yes` or `0/n/no`, and a blank value keeps
   the key's default. This removes a duplicated parse between the pre-open read
   and `LoadConfig`.

Defaults for users who change nothing are identical to before.

## Exact steps

```bash
# 1. fork on GitHub, then clone your fork
git clone git@github.com:<you>/mewjector.git
cd mewjector

# 2. branch
git checkout -b fix/ep-fallback-optout-and-logging

# 3. apply the patch
git apply /path/to/mewgenics-breeding-mod/patches/mewjector-epfallback-and-logging.patch
git add version.c chainloader.ini

# 4. commit
git commit -F- <<'MSG'
Add Chainloader/EnableEPFallback opt-out and honour Logging=0

On some Proton/Wine setups, patching the game's PE entry point races with game
startup: the process can hang before any mod loads, with the log ending after
[EP-fallback] Entry point restored.

- Chainloader/EnableEPFallback (default 1, unchanged). 0 skips the patch; mods
  load on the first version.dll proxy call. A WARNING states the risk.
- Logging was parsed but never read. Read it before opening the log file so
  Logging=0 creates no file and writes nothing. Crash reports under
  mod_logs/crashes remain separate.
- Parse booleans through one helper; blank keeps the default.

See also issue #4 (explicit init entry point).
MSG

# 5. build exactly as the README says (MSVC)
build.bat        # produces version.dll

# 6. push and open the PR
git push -u origin fix/ep-fallback-optout-and-logging
```

Open the PR against `main` with the title and body below.

## PR title

```
Add Chainloader/EnableEPFallback opt-out and honour Logging=0
```

## PR body

```markdown
Loading mods through Mewjector occasionally hangs the game at startup under
Steam Proton, before any mod loads. Roughly one launch in three here; retrying
usually works, so it is a race.

Environment: Mewgenics 1.1.b21239 (buildid 25143593), Proton Experimental,
Steam Linux Runtime 4.0, `WINEDLLOVERRIDES="version=n,b"`, Mewjector v3.4.

The log ends inside the entry-point fallback path, with no
`First proxy call — loading mods` line:

    [EP-fallback] Handler invoked (g_modsLoaded=0).
    [EP-fallback] Async mod-loader spawned.
    [EP-fallback] Entry point restored; returning to trampoline.
    [VEH] tid=332 code=0xC0000094 ...
    [VEH] null-rgn diag: fault in ntdll.dll+0x1B2C8
    <no further output; two threads left in futex wait, no window>

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
  default (previously the inline parses disagreed on empty values).

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

Happy to test a build if that helps. Longer term, #4 (explicit init entry point)
would remove the need for the entry-point patch.
```

## Posting on your behalf

Not done: opening the issue, opening the PR, and pushing a branch all need your
GitHub credentials. If you want me to do it, provide a token with `repo` scope
through the masked prompt; it is injected into the command only and never shown.
Otherwise the steps above are everything.
