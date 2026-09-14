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
| Our build toolchain works | `zig cc -target x86_64-windows-gnu -fms-extensions` builds the mod; the shipped loader is the official Mewjector release |
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
src/bridge_client.c   CRT-free Winsock sender: focus requests to the overlay
src/shortcut_watcher.c always-on Ctrl+Shift+B watcher: raise the overlay in any mode
src/crt_shim.c        KERNEL32-only mem/str/heap replacements for MewUI's CRT calls
src/crt_format.c      the snprintf/vsnprintf/_snwprintf half of that shim
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
imports anything but `KERNEL32.dll`, runs any `check*.sh` scripts the repository
ships, packs the installer bundle, and publishes it on the
[releases page](https://github.com/thebeardbe/mewgenics-breeding-mod/releases).

That bundle is `MewgenicsBreedingMod-install-vX.Y.Z.zip`: the three files from
`dist/`, plus everything in `installers/` (both installers, both uninstallers,
`proton-registry.sh`, and the install README), flat in one folder. Pushes and
pull requests to `master` run the same build, but only a tag creates a release.

A fast shell check can live anywhere in the repository as a `check*.sh` script;
CI discovers and runs every one of them. There are none today, so that step
passes cleanly.

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
- We ship the official Mewjector release as the loader and build our mod DLLs
  CRT-free (importing only `KERNEL32.dll`) as a precaution, but neither was what
  fixed the crash. See `RESEARCH.md` for the corrected account.

## Install

The mod ships as `MewgenicsBreedingMod-install-vX.Y.Z.zip` (tagged releases;
see [Release](#release)). It holds the three mod files (`version.dll`,
`chainloader.ini`, `BreedingSpike.dll`) and the installer scripts for both
systems, flat in one folder, with the install steps in the bundle's
`README.md`. Unpack it anywhere and keep the folder together. Releases publish
it on the
[releases page](https://github.com/thebeardbe/mewgenics-breeding-mod/releases).
None is published yet, so until one is you can build the same zip yourself:
`./build.sh`, then pack the contents of `installers/` together with the three
files from `dist/`.

### Windows

1. Unpack the zip.
2. Double-click `install.bat`.
3. Start Mewgenics normally. Windows needs no launch option and no registry
   change.
4. To undo, double-click `uninstall.bat`.

### Linux and NixOS (Proton)

1. Unpack the zip.
2. Run `./install.sh` in a terminal.
3. Set this Steam launch option (Mewgenics -> Properties -> Launch Options):

   ```
   WINEDLLOVERRIDES="version=n,b" %command%
   ```

   Wine prefers its own `version.dll`, so this override is what makes the game
   load ours. The `,b` matters just as much; see Proton constraints above.
4. Start Mewgenics normally.
5. To undo, run `./uninstall.sh`.

### Uninstall and dry runs

Both uninstallers ask for confirmation first and name the game folder, remove
only the files the installer recorded, and put back anything it replaced from
its timestamped backup. Declining, or running one twice, removes nothing. Both
refuse to run while Mewgenics is open. `-DryRun` (Windows) and `--dry-run`
(Linux) report what would happen and change nothing, for install and uninstall
alike.

**Achievements stay ON** for this standalone mod: nothing in the zip passes
`-modpaths` or enables the debug console, the only two things the game checks
before it turns Steam achievements off for the session.

After a launch, `<game folder>/mod_logs/chainloader.log` shows a banner, the hook
install line and one `cat key=... sqlKey=... name="..."` line per cat loaded.
Placing the files by hand, the flags, and what each file does are all in
[`installers/README.md`](installers/README.md).

## Achievement note

While the game runs with `-modpaths` (which Mewtator passes for mods) or with the
debug console enabled, the game turns Steam achievements off **for that session
only**. It writes nothing to `settings.txt` or the save, so launching without the
mod loader restores them. Details and the traced code are in `RESEARCH.md`.

## License

MIT for this repo's own code. Vendored upstream sources keep their own MIT
licenses; see `vendor/README.md`.
