# Mewgenics Breeding Mod

In-game bridge for the [Mewgenics Breeding Overlay](../mewgenics-breeding-overlay).
Long-term goal: add buttons in Mewgenics that load a cat into the overlay, and
eventually show the overlay's breeding analysis inside the game.

**Status: research / spike phase. Do not install yet unless you are helping
test.** Nothing here is a finished feature.

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
tools/smoke/          Wine tests for the loader pipeline and the sender
vendor/sync.sh        fetch pinned mewjector + mewui revisions
RESEARCH.md           findings, RVAs, references
```

## Build

```bash
nix develop          # or: nix-shell
./build.sh
```

Produces `dist/version.dll`, `dist/chainloader.ini`, `dist/BreedingSpike.dll`.

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

## Installing in the game (Steam + Proton)

1. Build (`./build.sh`).
2. Copy `dist/version.dll` and `dist/chainloader.ini` into the game directory:
   `~/.local/share/Steam/steamapps/common/Mewgenics/`
3. Create `mods/` there and copy `dist/BreedingSpike.dll` into it.
4. **Required on Linux/Proton:** force Wine to use our `version.dll` instead of
   its builtin. Steam -> Mewgenics -> Properties -> Launch Options:
   `WINEDLLOVERRIDES="version=n,b" %command%`
5. Launch the game and load a save. Then read:
   `~/.local/share/Steam/steamapps/common/Mewgenics/mod_logs/chainloader.log`

You should see the banner, the hook install line, and one
`cat key=... sqlKey=... name="..."` line per cat loaded.

To uninstall: delete `version.dll`, `chainloader.ini`, `mods/BreedingSpike.dll`,
and `mod_logs/`.

## Achievement note

While the game runs with `-modpaths` (which Mewtator passes for mods) or with the
debug console enabled, the game turns Steam achievements off **for that session
only**. It writes nothing to `settings.txt` or the save, so launching without the
mod loader restores them. Details and the traced code are in `RESEARCH.md`.

## License

MIT for this repo's own code. Vendored upstream sources keep their own MIT
licenses; see `vendor/README.md`.
