# PR kit: Mewjector `EnableEPFallback` opt-out + honour `Logging=0`

Everything here is ready to use. Nothing has been posted anywhere.

- Upstream: `githubuser508/mewjector`, default branch `main`
- Verified base: `ccdd681` (upstream `main` at the time of writing)
- Patch (one commit): `patches/mewjector-epfallback-and-logging.patch`
- Patch (two commits, recommended): `patches/mewjector-01-honour-logging-flag.patch` then `patches/mewjector-02-enable-ep-fallback-optout.patch`
- Both apply with `git apply` from the repo root and produce identical trees
- Issue text: `docs/upstream-mewjector-startup-hang.md`

## What the change does

1. `Chainloader/EnableEPFallback` (default `1`). Set to `0` to skip
   `PatchEntryPointFallback()`. Mods then load on the game's first `version.dll`
   proxy call. This avoids the entry-point patch race that intermittently hangs
   startup under Proton.
2. `Logging=0` now works. It was parsed into `g_config.logging` but never read.
   A flag is set before the log file is opened, so `Logging=0` produces no log
   output and creates no log file.

## Exact steps

```bash
# 1. fork on GitHub, then clone your fork
git clone git@github.com:<you>/mewjector.git
cd mewjector

# 2. branch
git checkout -b fix/ep-fallback-optout-and-logging

# 3a. two commits (recommended)
git apply /path/to/mewgenics-breeding-mod/patches/mewjector-01-honour-logging-flag.patch
git add version.c
git commit -m "Honour Chainloader/Logging: Logging=0 now writes nothing"

git apply /path/to/mewgenics-breeding-mod/patches/mewjector-02-enable-ep-fallback-optout.patch
git add version.c chainloader.ini
git commit -m "Add Chainloader/EnableEPFallback to skip the entry-point patch"

# 3b. or one commit
# git apply /path/to/mewgenics-breeding-mod/patches/mewjector-epfallback-and-logging.patch
# git add version.c chainloader.ini
# git commit -m "Add EnableEPFallback opt-out and honour Logging=0"

# 4. build exactly as the README says (MSVC)
build.bat        # produces version.dll

# 5. push and open the PR
git push -u origin fix/ep-fallback-optout-and-logging
```

Then open the PR against `main` with the title and body below.

## Commit messages

Commit 1:

```
Honour Chainloader/Logging: Logging=0 now writes nothing

Logging was parsed into g_config.logging but never read, so Logging=0 had no
effect. Read the flag before opening the log file so it produces no output and
creates no file.
```

Commit 2:

```
Add Chainloader/EnableEPFallback to skip the entry-point patch

On some Proton/Wine setups, patching the game's PE entry point races with game
startup: the process can hang before any mod loads, with the log ending after
[EP-fallback] Entry point restored. Add an ini opt-out (default 1, unchanged
behaviour). With EnableEPFallback=0, mods load on the first version.dll proxy
call instead.

See also issue #4 (explicit init entry point), which removes the need for the
patch entirely.
```

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
- `Logging=0` now has an effect. It was parsed but never read. The flag is read
  before the log file is opened, so no output and no file are produced.

## Evidence

- Patch applies to `main` at `ccdd681`.
- Built with MSVC per the README; exports unchanged (43 entries).
- Wine harness, same mod and one proxy call in every case:
  - `EnableEPFallback=1, Logging=1`: entry patched, first proxy call, mod loaded
  - `EnableEPFallback=0, Logging=1`: no entry patch, "Entry-point fallback
    disabled", first proxy call, mod loaded
  - `Logging=0`: no log file created
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
