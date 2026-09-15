# Mewgenics Breeding Mod

In-game bridge for the [Mewgenics Breeding Overlay](../mewgenics-breeding-overlay).
Long-term goal: add buttons in Mewgenics that load a cat into the overlay, and
eventually show the overlay's breeding analysis inside the game.

**Status: early testing.** The mod works on Linux under Proton (selection both
ways, the cat detail pane, save following) and has a one-click installer. The
Windows installer has not been run on real Windows yet, which is the test in
progress. Treat it as a beta.

Read [`RESEARCH.md`](RESEARCH.md) first. It is the map of the modding stack, the
game internals we have reversed, the RVAs, and the open questions.

## What is proven so far

| Claim | Evidence |
|---|---|
| Mewjector loads a mod DLL and the v3 API answers | `tools/smoke/run_smoke.sh` passes under Wine 11 |
| Our build toolchain works | `zig cc -target x86_64-windows-gnu -fms-extensions` builds the mod; the bundled loader is built from the patched Mewjector source the same CRT-free way |
| Shipped DLLs import only `KERNEL32.dll` | checked with `objdump -p`; a UCRT-importing (`api-ms-win-crt-*`) build crashes the game at launch under Proton |
| MewUI's RVAs match this game build | `mewgenics-ui-api`'s resolver matches every symbol against build `25143593` |
| The overlay's `db_key` is the game's cat key | `MewSaveFile::Load` stores its `__int64` key into `CatData.sqlKey` at RVA `0x230101`; confirmed in-game: 18/18 logged cats matched the overlay's save parse |
| The mod loads in the real game under Proton | `mod_logs/chainloader.log`: loader, API, hook install, `Integrity check: ALL OK` |
| The mod can reach the overlay | `src/bridge_client.c` (CRT-free Winsock, dynamic `ws2_32`) validated locally: a Wine mod queued key 341 and the overlay logged `bridge: focusing cat key=341` |
| In-game selection drives the overlay live | hook on `set_current_cat` (RVA `0xEBBA0`): click Bert logged `selected cat key=423`, and the overlay logged `bridge: focusing cat key=423` 74 ms later; next/previous tracked too |
| The overlay can select a cat in game | `Ctrl+G` sent key 407; the mod logged `house cat list has 18 entries` / `found at index 7, applying` and the game switched cats |
| Achievements are not permanently disabled | `disable_achievements` is only ever read; see `RESEARCH.md` |

Not yet proven: the cat-select-in-game path (overlay to game), and the MewUI
button.

## Layout

```
build.sh              build dist/version.dll + dist/BreedingSpike.dll
flake.nix, shell.nix  dev shell (zig, python3, binutils, git)
src/spike_mod.c       probe: MewSaveFile::Load (roster) + CatSelector::init (selection)
src/save_diag.c       TEMPORARY one-shot save-path probe (read-only; runs once)
src/mem_read.c        shared VirtualQuery pointer-readability check
src/bridge_client.c   CRT-free Winsock sender: focus requests to the overlay
src/shortcut_watcher.c always-on Ctrl+Shift+B watcher: raise the overlay in any mode
src/crt_shim.c        KERNEL32-only mem/str/heap replacements for MewUI's CRT calls
src/crt_format.c      the snprintf/vsnprintf/_snwprintf half of that shim
src/loader_crt.c      file-I/O and _stricmp half, for the patched loader's CRT-free build
tools/smoke/          Wine tests for the loader pipeline and the sender
installers/           one-click installers and uninstallers (Windows, plus
                      Linux/Proton)
vendor/sync.sh        fetch pinned mewjector + mewui revisions
RESEARCH.md           findings, RVAs, references
```

## Build

```bash
nix develop          # or: nix-shell
./build.sh
```

Produces `dist/version.dll`, `dist/chainloader.ini`, `dist/BreedingSpike.dll`.

## Release

The tag is the version. Cutting a release is just:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

GitHub Actions ([`.github/workflows/release.yml`](.github/workflows/release.yml))
does the rest: it builds through the pinned Nix dev shell, fails if either DLL
imports anything but `KERNEL32.dll`, runs the shell checks the repository ships
(every executable shell script under a `tests/` directory, run inside the dev
shell with Wine available), assembles both platform bundles, and publishes them
on the
[releases page](https://github.com/thebeardbe/mewgenics-breeding-mod/releases).

Each tag gets one release with two assets, one bundle per platform:

- `MewgenicsBreedingMod-vX.Y.Z-windows.zip`
- `MewgenicsBreedingMod-vX.Y.Z-linux.zip`

Each zip is self-contained for its platform:

```
install.bat / install.sh        entry script
uninstall.bat / uninstall.sh    uninstaller
scripts/                        installer helpers (install.ps1, loader-release.*, proton-registry.sh)
payload/                        version.dll, chainloader.ini, BreedingSpike.dll
docs/                           HOW-IT-WORKS.md, PATCHES.md, MEWJECTOR-LICENSE.txt
README.md                       that platform's install and uninstall steps
```

The `payload/`, `docs/` and `README.md` are the same in both; only the entry
scripts and helpers differ. Pushes and pull requests to `master` run the same
build, but only a tag creates a release.

A shell check is any executable shell script under a `tests/` directory; CI
discovers and runs all of them with the cross-compiler and Wine available, so a
check that builds a DLL and runs it under Wine works too. A non-zero exit from
any check fails the job.

## Local smoke test (no game)

```bash
nix shell nixpkgs#wine64 --command ./tools/smoke/run_smoke.sh
```

This builds a harmless mod plus a throwaway exe, runs them under Wine, and
checks `mod_logs/chainloader.log`.

## Proton constraints (learned the hard way)

- **`WINEDLLOVERRIDES="version=n,b"` is required.** The `,b` (builtin fallback)
  is not optional. With `version=n` alone, Wine forces our 64-bit DLL on every
  process in the prefix, 32-bit processes cannot load it and die, and the game
  launch aborts silently with no log.
- The loader that fixed the intermittent startup hang is a patched Mewjector
  (`EnableEPFallback` plus honouring `Logging=0`, PR #6), which is not upstream
  yet; the bundle ships that patched build as its fallback. Both it and our mod
  DLL import only `KERNEL32.dll`, so nothing under Proton pulls in a UCRT. See
  `RESEARCH.md` and `installers/PATCHES.md`.

## Install

The mod ships as two platform downloads on the
[releases page](https://github.com/thebeardbe/mewgenics-breeding-mod/releases):

- **Windows:** `MewgenicsBreedingMod-vX.Y.Z-windows.zip`
- **Linux and NixOS (Proton):** `MewgenicsBreedingMod-vX.Y.Z-linux.zip`

Pick your platform, unpack the zip, keep the folder together, and follow the
`README.md` inside it. That README has only your platform's install and
uninstall steps and points at the bundle's `docs/`: `docs/HOW-IT-WORKS.md` for
the loader, the three files, dry runs, re-installing, uninstalling, and where
the loader came from; `docs/PATCHES.md` for the loader patch and the upstream
PR; and `docs/MEWJECTOR-LICENSE.txt` for Mewjector's MIT licence.

No release is published yet, so until one is you can build the same bundles
yourself: `./build.sh --patched`, then lay out the files as the
[release workflow](.github/workflows/release.yml) does.

**Achievements stay ON** for this standalone mod: nothing in the zip passes
`-modpaths` or enables the debug console, the only two things the game checks
before it turns Steam achievements off for the session.

After a launch, `<game folder>/mod_logs/chainloader.log` shows a banner, the hook
install line and one `cat key=... sqlKey=... name="..."` line per cat loaded.
Placing the files by hand, the flags, and what each file does are all in
[`installers/HOW-IT-WORKS.md`](installers/HOW-IT-WORKS.md).

## Achievement note

While the game runs with `-modpaths` (which Mewtator passes for mods) or with the
debug console enabled, the game turns Steam achievements off **for that session
only**. It writes nothing to `settings.txt` or the save, so launching without the
mod loader restores them. Details and the traced code are in `RESEARCH.md`.

## License

MIT for this repo's own code. Vendored upstream sources keep their own MIT
licenses; see `vendor/README.md`.
