# How the installers work

The detail behind the two installers. For the steps themselves, see the
`README.md` in the bundle you unpacked.

The standalone build places a Mewjector loader (`version.dll` and
`chainloader.ini`) next to the game executable and our mod (`BreedingSpike.dll`)
in the game's `mods/` folder so the overlay can follow the cat you select.

## What the three files do

- `version.dll` - the Mewjector loader, a proxy for the Windows `version` API:
  the game loads it as if it were the system DLL, and it then loads Mewjector
  and the mods. This bundle ships a patched build until the fix from
  [Mewjector PR #6](https://github.com/githubuser508/mewjector/pull/6) lands
  upstream; the installer prefers the official loader once it carries that fix.
  See `PATCHES.md`.
- `chainloader.ini` - Mewjector's settings. It points the loader at the `mods/`
  folder and controls its logging.
- `BreedingSpike.dll` - our mod. It hooks save loading and selection and talks
  to the overlay over the bridge. It goes in `mods/`, not beside the executable.

`proton-registry.sh` is a helper sourced by `install.sh` (the optional Wine
prefix override); `loader-release.sh` and `loader-release.ps1` are the helpers
that decide between the bundled and upstream loaders. The bundle keeps every
helper in `scripts/`, beside the script that uses it.

## Where the bundle keeps the files

The zip is meant to be unpacked whole. The installer finds the three artifacts
with a candidate search, in this order:

1. a `payload` folder inside the installer script's own folder,
2. a `payload` folder beside that folder,
3. the script's own folder.

A complete folder with all three files beside the installer (a flat unpack) is
used as it is, whatever else is nearby, so a stray `payload` folder cannot
shadow it. When the folder is incomplete each file is resolved on its own: the
first candidate that has it wins, and a payload copy beats a stray copy beside
the script. A missing file is reported at the folder the search actually
reached, never at a folder that does not exist.

The older flat layout and the older `windows/`+`linux/`+`payload/` layout both
keep working: the helper lookup tries `scripts/` first and falls back to beside
the entry script, and the payload search accepts a payload folder beside the
script's parent folder.

## Why the game finds the loader

Windows searches the game folder before the system directory, so a native
`version.dll` beside `Mewgenics.exe` shadows the system one. On Linux the game
runs under Wine/Proton, which prefers its builtin `version.dll`, so the loader
needs a DLL override (the launch option in the Linux README).

The `,b` is required, not cosmetic: `version=n` alone forces our 64-bit DLL on
every process in the prefix, the 32-bit ones fail to load it, and the game
launch aborts silently. `,b` falls back to Wine's builtin elsewhere.

## Achievements stay ON

Nothing here passes `-modpaths` or enables the debug console, the only two
things the game checks before it turns Steam achievements off for a session.
The mod is loaded beside the game and the mod DLL is read from `mods/`, so no
achievement-disabling launch flag is involved.

## Where the loader comes from

The installer puts one of two loaders in the game folder and prints which one it
used and why.

- **The official Mewjector release, downloaded over HTTPS.** The installer asks
  the official Mewjector GitHub release API for the latest release and accepts
  only an asset URL under
  `https://github.com/githubuser508/mewjector/releases/download/`; any other URL
  is refused. It then prints the source URL and the SHA-256 of the installed
  `version.dll`, so you can compare that hash against the release you expected
  (for example the one in a release note).
- **The patched loader bundled with this installer.** This is the build in this
  zip, used while upstream does not yet carry the fix.

`MEWJECTOR_RELEASE_OVERRIDE` is a **trusted developer and mirror hook**: it
points the loader check at a local folder, ini or metadata file instead of
GitHub, so the offline checks, development, and users behind a mirror can work.
It is **deliberately not verified**: nothing checks the hash or the origin of
the loader it names, and the installer trusts whatever is there. Only set it to
a loader you trust (your own build, or a release you fetched and checked
yourself). The installer will not accept a loader from any other place.

A relative `chainloader_ini=` path in an override metadata file resolves against
that metadata file's own folder, the same as `directory=`, so the result does
not depend on the folder you ran the installer from.

## Flags and dry runs

```
install.bat -DryRun                       # report only, change nothing
install.bat -Uninstall                    # remove the recorded files, restore backups
install.bat -GameDir "D:\Games\Mewgenics" # non-standard location
install.bat -BundledLoader                # force the bundled patched loader

./install.sh --dry-run                    # report only, change nothing
./install.sh --uninstall                  # remove the recorded files, restore backups
./install.sh --game-dir /path/to/Mewgenics
./install.sh --bundled-loader             # force the bundled patched loader
```

`-DryRun` and `--dry-run` show what would happen without changing anything, for
install and uninstall alike. The uninstall wrappers take it too
(`uninstall.bat -DryRun`, `./uninstall.sh --dry-run`). A dry run never downloads
a loader and never writes to a Proton prefix.

## What a re-install does

The installer finds Mewgenics through the Steam library folders, backs up any
file it replaces, skips files that are already up to date, and refuses to run
while the game is open. Running it twice is harmless.

## Writing the override into the Proton prefix

Instead of the launch option, the script can write the same override into the
game's Proton prefix (`compatdata/686060/pfx/user.reg`). It asks first and
leaves the prefix alone if you say no. This is Linux only; Windows needs no
registry change.

## Undo an install

After a successful install the installer writes a small record inside the game
folder, `mods/.breeding-spike-installed`, listing the files it placed:
`version.dll`, `chainloader.ini`, and `mods/BreedingSpike.dll`. Uninstall only
touches a file the record lists and that still has the exact content the
installer wrote, so a file you replaced by hand is left alone.

One consequence: if the installer used the official upstream loader (rather
than the bundled patched one), its `version.dll` and `chainloader.ini` do not
match the bundle, and uninstall leaves them in place like any other file that
changed after install. Delete those two by hand if you want the game folder
clean; `BreedingSpike.dll` is removed as usual.

Both installers keep a timestamped backup beside any file they replace, for
example `version.dll.20260914-130739.bak`, and report it when they create one.
Uninstall restores the newest backup of each recorded file, ordered by the
stamp in the backup name, if there is one. Backups are left in place. Only
names of that exact shape count, so a stray `version.dll.old.bak` is ignored
rather than restored over the installed file.

If uninstall leaves a recorded file in place (you changed it, or the bundle is
incomplete and it cannot be checked), it keeps the record, rewritten to list
only the files still present, and says so. The record is deleted only once
everything it lists is gone, so a later run can finish the cleanup.

If there is no record, uninstall removes nothing and says so, naming every file
it deliberately leaves. That protects a game folder that was set up by Mewtator
or a manual Mewjector install rather than through these scripts.

The wrappers only ask for confirmation, naming the game folder, and then hand
over to the installer, so uninstalling is as easy as installing. A second run is
safe, and without a terminal to ask on the Linux uninstaller stops rather than
assuming yes.

The installers never remove `mod_logs/`, saves, or any other game file. Delete
`mod_logs/` by hand if you want the loader logs gone.
