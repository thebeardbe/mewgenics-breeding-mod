# RESEARCH: in-game integration for the Mewgenics Breeding Overlay

Status: research phase. Nothing here is a build plan yet. This file exists so
the references and offsets survive between sessions. Every claim is tagged:

- **[V]** verified locally on this machine (game install, exe, gpak, save)
- **[R]** verified against a public repo or documented API
- **[I]** inferred, needs a spike to confirm

Local environment (this machine):

| Thing | Path |
|---|---|
| Game | `~/.local/share/Steam/steamapps/common/Mewgenics/` |
| Exe | `Mewgenics.exe` (image base `0x140000000`, `buildid 25143593`) |
| Assets | `resources.gpak` (5.1 GB, readable) |
| Saves (Proton) | `.../compatdata/686060/pfx/drive_c/users/steamuser/AppData/Roaming/Glaiel Games/Mewgenics/76561198863371232/saves/` |
| Settings | same dir, `settings.txt` (`disable_achievements false`, no `enable_debugconsole`) |
| Toolchain | NixOS. `nix shell nixpkgs#python3`, `pkgsCross.mingwW64.stdenv.cc`, `nixpkgs#binutils` all work |

The game runs under Proton on this machine, so an end-to-end test loop is
possible locally without a Windows box.

---

## 1. The overlay already expects this

The overlay is not a blocker and needs no rearchitecture.

- `src/mewgenics_overlay/ui/tablectl.py:84` `set_focus_key(db_key: int)` docstring:
  "Programmatic focus (used by the future in-game bridge)". **[V]**
- `src/mewgenics_overlay/ui/palette.py:504` public `PaletteWindow.set_focus_key`
  delegating to the coordinator. **[V]**
- `src/mewgenics_overlay/ui/palette.py:13` says an in-game hook bridge
  "(see core/bridge notes) can inject a cat key the same way `set_focus_key()` does". **[V]**
- `src/mewgenics_overlay/ui/tablectl.py:85` and `tests/test_tablectl.py` already
  cover set_focus_key behaviour. **[V]**

So the overlay-side work is: a new `core/bridge.py` plus wiring. It stays
read-only with respect to the game and the save. All game interaction lives in
this repo (the mod).

Cat identity in the overlay's model: `db_key` (SQLite `cats.key`),
`unique_id` (`CatData._uid_int`, a u64 seed), `name`.
On `steamcampaign02.sav`: 371 cats, 18 alive, all 18 alive names unique, all 18
uids unique. **[V]**

---

## 2. The modding stack

| Tool | Role | Needed? |
|---|---|---|
| **Mewtator** | Cross-platform mod manager. Owns `-modpaths`, asset extraction, load order, dev mode toggle, writes the DLL manifest Mewjector reads | Recommended for install/dev mode; not a hard dependency |
| **Mewjector** | `version.dll` proxy that loads DLL mods from `mods/`. Exports `MJ_InstallHook`, `MJ_QueryHook`, `MJ_AllocTypeIdPair`, `MJ_RegisterName`, `MJ_LookupName`, `MJ_GetGameBase`, `MJ_Log`, `MJ_VerifyHooks`, `MJ_GetVersion` (v3) | **Required** for a DLL mod |
| **MewUI API** | C helper over Mewjector for SWF/Scaleform UI: create/reuse buttons, hook existing buttons, set localized text, toggles, navigation, scene bindings. `MewUI_Start(...)` from `DllMain`, work runs on the scene-ready update hook | **Required** for adding/hooking UI |
| **Catstructor** | MIT DLL mod with source. In-game ImGui cat editor. Best public reference for reading scene cats and calling native RVAs by pattern | Reference |
| **Custom Stray Framework** | MIT DLL mod with source. Documents `CatData` layout, `MewDirector`/`CatDatabase` access, RVAs, and pattern signatures | Reference |
| **MewCatPartFramework / MewPaletteExtender** | Asset/content frameworks | Not needed |

`-modpaths` (Mewtator or a launch option) is what makes `.append` / SWF asset
mods load. Mewjector is what loads the DLL. For a DLL + SWF mod we want both.

### Achievements (traced in the binary) **[V]**

Community sources conflict, so this was traced directly. The conclusion is that
achievements are disabled **per launch, in memory**, and are restored by
launching without the mod loader.

- `disable_achievements` is a settings key (local `settings.txt` has it `false`).
  It is read once at startup into a flag. The string has exactly one reference in
  `.text` and that reference is a read, so the game never writes the key.
- `-modpaths` (what Mewtator passes when launching mods) sets the same in-memory
  flag to 1.
- `-enable_debugconsole true` (Mewtator's debug console toggle, or the settings
  key) also sets the flag to 1 and clears a global `achievements allowed` byte.
- `-dev_mode true` (Mewtator's dev mode, required by Catstructor) does not touch
  the achievements flag.
- Nothing is persisted: not in `settings.txt`, not in the save. The save's
  `properties` and `files` tables contain no mod or cheat marker.

Implication for this project: asset mods need `-modpaths`, so a SWF/CSV `.append`
mod disables achievements while active. A **DLL-only + ImGui** build with no
`.append` assets might avoid `-modpaths` and leave achievements on. This is an
argument for the ImGui rendering path over MewUI+SWF for the in-game overlay.

Relevant RVAs/globals: settings getter `0x9D3790`; achievements flag reads/writes
around `0x9BCCD0` (reads `disable_achievements`), `0x9B8BB0` (`-modpaths`),
`0xA11EF0` (`enable_debugconsole`); globals `[0x1413C58B0]` (achievements allowed)
and `[settings_singleton(0x1413C4A30) + 0x368]` (disabled flag).

---

## 3. Game internals discovered from the local exe

The exe has no PDB and no exported symbols, but it is **not stripped of RTTI or
assert strings**. That gives an unusually good map:

- MSVC RTTI type descriptors: `. ?AV<Class>@glaiel@@`, 1957 distinct
  `glaiel::` classes. **[V]**
- Assert strings include **stringified function signatures**, e.g.
  `void __cdecl glaiel::CatSelector::init(__int64)` (188 signatures recovered). **[V]**
- Assert strings include **source file paths**, e.g.
  `C:\Users\Tyler\Desktop\SVN\Mewgenics\game\code\CatSelector.cpp` (44 files). **[V]**
- Mangled lambda ownership leaks method names for classes that use lambdas. **[V]**

Useful recovered classes/signatures:

| Symbol | Notes |
|---|---|
| `glaiel::CatData` | `breed`, `set_class`, `MutatePiece` (from RTTI lambdas) |
| `glaiel::CatDatabase` | `RVA_CREATE_STRAY_CATDATA` doc: alloc/init stray CatData |
| `glaiel::HouseCat` | `init(__int64, FurnitureEffects*)`, `update`, `late_update` |
| `glaiel::HouseCatClickManager` | component, likely the click/selection path |
| `glaiel::CatSelector` | `init(__int64)`, `ShowCatClassTooltip`, `ShowCatMutationTooltips` |
| `glaiel::FamilyTree` | `init(__int64, function<void()>)`, `gen_cats`, `Exit` |
| `glaiel::CatStatsDrawer` | `ShowFamilyTree`, `init` |
| `glaiel::MenuPanel` | `register_button(name, label, function<void()>)`, `register_selector`, `register_toggle`, `init` |
| `glaiel::MewSaveFile` | `Load(__int64, CatData&)`, `Load(__int64, FurniturePieceEntry&)` |
| `glaiel::SerializeCatData(CatData&, ByteStream&, bool)` | save serialization |
| `glaiel::Pedigree` | `LoadFromFile(ByteStream&, __int64)` |
| `glaiel::Director` | `DispatchEvent<string, CatData*>`; `EventListener::call<const char*, CatData*>` |
| `glaiel::ImmediateModeGameUI`, `IMGUISceneBase` | native ImGui UI |
| `glaiel::MewDirector` | `StartAdventure`, `ReturnToHouseSuccess`, `DebugGenAdventureCats`, ... |

`MewSaveFile::Load(__int64, CatData&)` is the strongest evidence that the save's
`cats.key` and the runtime `CatData` key are the same int64. So **[I, high
confidence]**: the overlay's `db_key` equals the game's cat key and equals
`CatData.sqlKey`.

### CatData layout (from Custom Stray Framework `game_runtime_types.h`) **[R]**

```
CatData:
  +0x18   WideString name        (32 bytes; <=7 wchar inline, else heap)
  +0x58   int32 gender
  +0x60   parts/custom compartment (Catstructor CAT_DATA_PARTS_OFFSET)
  +0x6F0  int32[7] heritable stats
  +0x70C  int32[7] level-up deltas
  +0x728  int32[7] injury deltas
  +0x7D0  NarrowString[2] basic actives
  +0x810  NarrowString[4] accessible actives
  +0x910  Passive slot 0
  +0x960  Disorder slot 0
  +0x9B0  equipment slots, stride 0x60
  +0xBB8  libido
  +0xBC0  sexuality
  +0xBC8  lover uid
  +0xBD8  rival uid
  +0xBE8  aggression
  +0xBF0  fertility
  +0xBF8  flags (0x200000 = no-breed)
  +0xC38  birth day
  +0xC40  death day
  +0xC48  int64 sqlKey      <-- overlay db_key
  +0xC50  inbreeding
```

### Accessing live cats

- MewDirector singleton: absolute pointer at `gameBase + 0x13DAC30`. **[R]**
  - `MewDirector + 0x28` -> `Director` (scene vector). **[R]**
  - `MewDirector + 0x598` -> `CatDatabase*`. **[R]**
- House scene cat vector: `Scene + 0x168`. **[R, Catstructor]**
- Cat visual -> CatData: `CatVisual + 0x8A8`. **[R, Catstructor]**
- Custom cat lookup RVA `0x942DA0` (used by `CatSelector::init`). **[V]**

Two independent ways to reach a cat by key:
1. Walk `Scene + 0x168`, each `CatVisual + 0x8A8` -> `CatData`, compare `sqlKey`.
2. Use `CatDatabase` / `MewSaveFile::Load(key, CatData&)` style lookup.

---

## 4. The House UI (where buttons live)

`resources.gpak -> swfs/house.swf` is uncompressed (`FWS`, SWF v17) and its
`SymbolClass` exports include **[V]**:

`CatMenu`, `HouseNametag`, `HouseStatusUI`, `HouseStatusUIEndDayonly`,
`RoomStatsUI`, `NPCMenu`, `StorageMenu`, `TrashMenu`, `FurnitureButton`,
`ButchBox`, `HouseShopShortcuts`, plus backgrounds/pipe/tree.

Node names recovered from the SWF and from the exe ABC/string tables **[V]**:

| UI | Nodes |
|---|---|
| `CatMenu` | `openclose`, `clickblock`, `page_left`, `Stats`, `HouseCatStatus`, `topipe`, `tobox` |
| House cat layer | `cats`, `catname`, `nametag_button`, `nextcat_left`, `nextcat_right`, `catpages`, `catpagesH` |
| `HouseStatusUI` | `statsbox`, `appealbox`, `comfort`, `evolution`, `datebox`, `depart` |
| `HouseNametag` | `catname` |
| `CatChooser` (SWF screen) | `cats`, `left`, `right`, `okbtn`, `cancelbtn`, `catname`, `prompt` |
| `StorageMenu` | `ref_grid`, `storagename`, `questitems`, `sort_abc`, `sort_type`, `sort_rarity`, `sort_time` |

So the per-cat interaction surface is the `nametag_button`, which opens
`CatMenu` (Stats / HouseCatStatus / topipe / tobox), and the House has its own
cat paging (`nextcat_left` / `nextcat_right`, `catpages`). The cat UI setup
function that binds all of these is at RVA `0xE9AC0` (see below). **[V]**

---

## 5. Located RVAs (game build 25143593)

All RVAs are relative to the module base. Function ranges confirmed from the PE
`.pdata` exception directory. **[V]**

| RVA | What | Evidence |
|---|---|---|
| `0xE9AC0` .. `0xEAC62` | House cat UI setup: binds `Stats`, `HouseCatStatus`, `topipe`, `tobox`, `nametag_button`, `nextcat_left`, `nextcat_right`; calls the CatMenu attach | xrefs to those strings |
| `0xEF570` .. `0xEF72C` | CatMenu attach helper: looks up `cats` + `CatMenu` | xref to `CatMenu` |
| `0x1F8F60` .. `0x1FABE7` | House cat entity creation (`catname`, nametag wiring); near `RVA_SCENE_CREATE_HOUSECAT_I64 0x1F5F00` | xrefs to `catname` |
| `0x1ACE50` .. `0x1AD07C` | Component constructor, caller `0x1A3B8A`; neighbouring class is `HouseCatClickManager` | disassembly + RTTI |
| `0xDE040` .. `0xDF2D6` | `glaiel::CatSelector::init(__int64)`; calls `CatVisual refresh 0x73F7D0` and custom cat lookup `0x942DA0` | xref to its assert signature |
| `0x230060` .. `0x230245` | `glaiel::MewSaveFile::Load(__int64, CatData&)` | xref to its assert signature |
| `0x22F410` .. `0x23005D` | `glaiel::SerializeCatData(...)` | xref to its assert signature |
| `0x773D00` .. `0x774BE6` | `glaiel::Pedigree::LoadFromFile(...)` | xref to its assert signature |

Also from the two reference mods **[R]**:

| RVA / offset | What |
|---|---|
| `0x1EE8E0` | `House` stray generation |
| `0x1F5F00` | Scene create HouseCat from int64 key |
| `0x0D7160` | CatDatabase create stray CatData |
| `0x73F7D0` | Cat visual refresh |
| `0x942DA0` | Custom cat lookup |
| `0x13DAC30` | MewDirector singleton |
| `0x13C5530` | Localization manager |

MewUI's own pattern-resolved RVAs (button setup, hooking, scene-ready update)
live in `mew_ui_api.h` and `re_tools/mew_ui_api_signatures.json` and are
resolved by pattern, not hardcoded. **[R]**

---

## 6. Rendering options for the future in-game overlay

1. **MewUI + custom SWF.** Supported path for new UI. Needs an FLA authored in
   Adobe Animate (or reuse the MIT `house_ui_test.swf` from the MewUI repo,
   which already mounts `test_button` / `test_text` into the House scene). **[R]**
2. **Native ImGui.** The game ships Dear ImGui 1.91.0 WIP with
   `imgui_impl_opengl3` + `imgui_impl_sdl3`, plus `ImmediateModeGameUI` and
   `IMGUISceneBase::draw()`. Catstructor renders an ImGui window from a scene
   draw hook. No SWF authoring. **[V][R]**
3. **External overlay follows the game** (no in-game rendering): the existing
   Qt window auto-focuses the cat the player selects. Cheapest path to "it
   feels in-game". **[I]**

The breeding math should stay single-sourced in the Python overlay. The most
coherent architecture is: mod sends selection to the overlay, overlay computes,
overlay sends structured rows back, mod renders them (option 1 or 2). Porting
the math to C would duplicate the one thing this project treats as a single
source of truth.

---

## 7. Techniques used (reusable)

Read-only, no game process required:

- **GPAK listing/extraction.** `resources.gpak` starts with `u32 count`, then
  `count` entries of `u16 name_len, name, u32 size`, then the file data
  concatenated in order. Enough to list and extract any asset, including
  `swfs/*.swf` and `data/text/combined.csv`. **[V]**
- **SWF node names.** `house.swf` is uncompressed; walk the tag stream, read
  `SymbolClass` (tag 76) for class names and `PlaceObject2/3` (26/70) `Name`
  fields for instance names. **[V]**
- **PE cross-references.** Parse `.text`, `.rdata`, `.pdata`; for a string RVA,
  find RIP-relative `lea`/`mov` references; map a reference to its containing
  function via `.pdata` `RUNTIME_FUNCTION` entries (55712 functions). **[V]**
- **Assert-signature mining.** Assert strings carry full function signatures
  and source paths. Cross-referencing a signature string lands inside that
  function, giving its RVA without a debugger. **[V]**
- **RTTI inventory.** `. ?AV<Class>@glaiel@@` gives the class list; lambda
  type names leak method names. **[V]**

Scratch tools used this session live in `/tmp` (`gpak_ls.py`, `gpak_x.py`,
`swf_tags2.py`, `swf_names2.py`, `pe_xref.py`, `pe_funcs.py`, `pe_callers.py`).
They should be cleaned up and, if kept, moved into a `tools/` dir with tests.

---

## 8. Open questions (what a spike must answer)

1. **Game to overlay (read the selected cat).** Best hook: the nametag/click
   path (`0xE9AC0` binds `nametag_button` with a callback object), or the
   `HouseCatClickManager`, or `CatSelector::init`. Need the callback signature
   and where the `CatData*` / cat key is available.
2. **Overlay to game (select a cat).** Candidates: call the CatMenu open path
   for a key, drive the House cat paging (`nextcat_left/right`, `catpages`), or
   call `CatSelector` / `FamilyTree::init(key)`. Need to confirm which one is
   safe to call from a hook and what state it expects.
3. **Confirm `db_key == CatData.sqlKey`.** Strongly suggested by
   `MewSaveFile::Load(__int64, CatData&)`. Prove it at runtime by logging
   `sqlKey` next to `name` and comparing with a save parse.
4. **Proton + Mewjector.** Does a `version.dll` proxy load under Proton, or does
   Wine's own `version.dll` override win? Must be tested before anything else.
5. **Transport.** TCP loopback is bidirectional (needed for overlay -> game and
   for rendering rows back). Confirm Wine/Proton reaches host `127.0.0.1`, and
   decide the protocol (JSON lines, versioned) and auth (bind loopback only).
6. **MVVM of the button.** Placement in `CatMenu` (per-cat action) versus
   `HouseStatusUI` (current cat). The user preference stated so far is
   `CatMenu`.
7. **RVA drift.** Every game patch moves RVAs. Adopt pattern resolution (like
   MewUI and the two frameworks) for anything we hardcode, and pin the target
   build id.
8. **Achievements.** Confirm impact of loading a `version.dll` mod.
9. **SWF authoring.** Does the user have Adobe Animate, or do we reuse the MIT
   `house_ui_test.swf` and ImGui for the first version?

---

## 9. M0 findings (validated on this machine)

These were checked during the first spike. They change the "unknowns" list above.

**Toolchain.** Mewjector and MewUI both use MSVC `__try`/`__except` (SEH).
GCC/mingw cannot compile them (no `__try`), and plain clang/zig cc also reject
`__try` until `-fms-extensions` is added. The working recipe is:

```
zig cc -target x86_64-windows-gnu -fms-extensions -O2 -shared ...
```

This builds `version.dll` (Mewjector) and mod DLLs that include `mew_ui_api.c`.
**[V]**

**Loader under Wine/Proton.** Mewjector works end to end under Wine 11: the
proxy loads, `mods/*.dll` load, and the v3 API (log, type ids, name registry)
answers. The catch: Wine prefers its **builtin** `version.dll`, so the native
proxy only runs with `WINEDLLOVERRIDES="version=n"`. Under Proton this must go
in the Steam launch options:

```
WINEDLLOVERRIDES="version=n" %command%
```

A second Wine quirk: on a fresh prefix, Wine tries to install mono/gecko and
hangs on a dialog with no display. Adding `mscoree,mshtml=` to the overrides
avoids it. Neither quirk is game code. **[V]**

**MewUI matches this build.** `re_tools/update_mew_ui_api_offsets.py --dry-run`
resolved every `MEW_RVA_*` / `MEW_OFF_*` symbol against build `25143593` with no
failures, so the scene/button/text helpers should work in-game. **[V]**

**`db_key == CatData.sqlKey` proven.** `glaiel::MewSaveFile::Load(__int64 key,
CatData& out)` is at RVA `0x230060`. Its body executes
`mov [rsi+0xC48], rdi` at RVA `0x230101`, storing the load key into
`CatData.sqlKey` (`+0xC48`). The save's `cats.key` is therefore the same integer
the game uses, and the bridge can send an integer, not a name. **[V]**

**Repo artifacts.** `build.sh` produces `dist/version.dll`,
`dist/chainloader.ini`, `dist/BreedingSpike.dll`. `tools/smoke/run_smoke.sh`
reproduces the loader proof under Wine. `tools/install_game.sh` copies the
artifacts into the Steam install and prints the launch options. `src/spike_mod.c`
is the read-only probe that hooks `MewSaveFile::Load` and logs
`cat key=... sqlKey=... name="..."`. **[V]**

Still open from the list above: the in-game load test on your Steam session,
and the cat-select-in-game (overlay to game) path.

## 10. References

Repos (all MIT unless noted):

- Mewjector: https://github.com/githubuser508/mewjector
  (local clone docs: `API.md`, `mewjector.h`)
- MewUI API: https://github.com/Pseudonym-Tim/mewgenics-ui-api
  (`mew_ui_api.h`, `src/native/example_mod/UIModTest.c`, `re_tools/mew_ui_api_signatures.json`)
- Catstructor: https://github.com/Pseudonym-Tim/mewgenics-catstructor
  (`src/Catstructor.h` offsets, `re_tools/catstructor_signatures.json`)
- Custom Stray Framework: https://github.com/Pseudonym-Tim/mewgenics-custom-stray-framework
  (`src/game_runtime_types.h` CatData layout, `re_tools/custom_stray_framework_signatures.json`)
- MewCatPartFramework: https://github.com/Pseudonym-Tim/mew-cat-part-framework
- MewPaletteExtender: https://github.com/Pseudonym-Tim/mew-palette-extender
- Mewtator: https://github.com/dancomstock/mewtator
- MewgenicsBreedingManager (overlay's vendored engine): https://github.com/frankieg33/MewgenicsBreedingManager
  and the fork https://github.com/whyayala/MewgenicsBreedingManager (v5.9.5)
- Breeding helper: https://github.com/PurpleMyst/mewgenics_breeding_helper

Docs and data:

- Modding wiki: https://mewgenics.wiki.gg/wiki/Modding (`-modpaths`, `.append`/`.merge`/`.patch`)
- Debug console wiki: https://mewgenics.wiki.gg/wiki/Debug_Console (`listcmds`)
- Breeding reverse engineering: https://gist.github.com/SciresM/95a9dbba22937420e75d4da617af1397
- WorldEvent reverse engineering: https://gist.github.com/SciresM/7d6870d42ab125e4d017c8023031e246
- GON format: https://github.com/TylerGlaiel/GON
- GPAK extractor: https://github.com/ShootMe/GPAK-Extractor
- Mewgenics Mod SDK docs (currently 404, try archive later): https://netfu.net/mewgenics/
- Save editor (binary field mapping): https://github.com/mzx521521/mewgenics-save-editor
- Cheat Engine thread (stale v1.0 offsets, do not trust): https://fearlessrevolution.com/viewtopic.php?f=2&t=38214

Overlay-side files that matter:

- `src/mewgenics_overlay/ui/tablectl.py` (`set_focus_key`)
- `src/mewgenics_overlay/ui/palette.py` (public focus entry point)
- `src/mewgenics_overlay/core/watcher.py` (debounce + safe copy pattern to reuse)
- `src/mewgenics_overlay/core/discovery.py` (Windows + Proton save roots)
