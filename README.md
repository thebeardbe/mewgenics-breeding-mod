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
| The overlay's `db_key` is the game's cat key | `MewSaveFile::Load` stores its `__int64` key into `CatData.sqlKey` at RVA `0x230101` |
| Achievements are not permanently disabled | `disable_achievements` is only ever read; see `RESEARCH.md` |

Not yet proven: that the DLL loads in the real game under Proton (needs your
Steam launch), and the cat-select-in-game path.

## Layout

```
build.sh              build dist/version.dll + dist/BreedingSpike.dll
flake.nix, shell.nix  dev shell (zig, python3, binutils, git)
src/spike_mod.c       the M0 probe (hooks MewSaveFile::Load, logs cat key/name)
tools/smoke/          Wine smoke test for the loader pipeline
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

- **Both DLLs must import only `KERNEL32.dll`.** A DLL that imports the UCRT API
  sets (`api-ms-win-crt-*`) crashes the game at launch under Proton, before
  anything is logged. The official Mewjector release already links its CRT
  statically; our mod is built with `-nostdlib` and a plain `DllMain` entry, so
  it must not use the C runtime (no `stdio.h`, no `string.h`; log formatting goes
  through Mewjector's `MJ_Log`). `objdump -p` on both DLLs should show only
  `KERNEL32.dll`.
- **`WINEDLLOVERRIDES="version=n"` is required** for the loader to be used at
  all. Wine otherwise prefers its builtin `version.dll`.

## Installing in the game (Steam + Proton)

1. Build (`./build.sh`).
2. Copy `dist/version.dll` and `dist/chainloader.ini` into the game directory:
   `~/.local/share/Steam/steamapps/common/Mewgenics/`
3. Create `mods/` there and copy `dist/BreedingSpike.dll` into it.
4. **Required on Linux/Proton:** force Wine to use our `version.dll` instead of
   its builtin. Steam -> Mewgenics -> Properties -> Launch Options:
   `WINEDLLOVERRIDES="version=n" %command%`
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
