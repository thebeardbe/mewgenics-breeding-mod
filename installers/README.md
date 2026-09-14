# Installing the Breeding mod

One-click installers for the standalone build: an official Mewjector loader
(`version.dll` + `chainloader.ini`) next to the game executable, and our mod,
`BreedingSpike.dll`, in the game's `mods/` folder.

Windows searches the game folder before the system directory, so a native
`version.dll` beside `Mewgenics.exe` shadows the system one. On Linux the game
runs under Wine/Proton, which prefers its builtin `version.dll`, so the loader
needs a DLL override (the launch option below).

**Achievements stay ON.** None of these installers passes `-modpaths` or enables
the debug console, the only two things the game checks before it turns Steam
achievements off for a session.

The installers expect the three artifacts beside them. Keep an unpacked release
folder together:

```
install.bat   uninstall.bat   install.ps1   README.md
install.sh    uninstall.sh    proton-registry.sh
version.dll   chainloader.ini   BreedingSpike.dll
```

`proton-registry.sh` is a helper sourced by `install.sh` (the optional Wine
prefix override); keep it beside the others.

## What the three files do

- `version.dll` - the official Mewjector loader. It is a proxy for the Windows
  `version` API: the game loads it as if it were the system DLL, and it then
  loads Mewjector and the mods.
- `chainloader.ini` - Mewjector's settings. It points the loader at the `mods/`
  folder and controls its logging.
- `BreedingSpike.dll` - our mod. It hooks save loading and selection and talks
  to the overlay over the bridge. It goes in `mods/`, not beside the executable.

## Windows

Double-click `install.bat` (or run
`powershell -ExecutionPolicy Bypass -File install.ps1`).

Uninstall by double-clicking `uninstall.bat`, which asks for confirmation first
and names the game folder it is about to clean.

The installer finds Mewgenics through the Steam library folders, backs up any
file it replaces, skips files that are already up to date, and refuses to run
while the game is open. Useful flags:

```
install.bat -DryRun                       # report only, change nothing
install.bat -Uninstall                    # remove the recorded files, restore backups
install.bat -GameDir "D:\Games\Mewgenics" # non-standard location
```

No registry changes and no Steam launch options are needed on Windows.

## Linux and NixOS (Proton)

Run `./install.sh`, and uninstall with `./uninstall.sh`, which asks for
confirmation first and names the game folder it is about to clean. The install
needs one Steam launch option, set in
`Steam -> Mewgenics -> Properties -> Launch Options`:

```
WINEDLLOVERRIDES="version=n,b" %command%
```

The `,b` is required, not cosmetic: `version=n` alone forces our 64-bit DLL on
every process in the prefix, the 32-bit ones fail to load it, and the game
launch aborts silently. `,b` falls back to Wine's builtin elsewhere.

```
./install.sh --dry-run                    # report only, change nothing
./install.sh --uninstall                  # remove the recorded files, restore backups
./install.sh --game-dir /path/to/Mewgenics
```

Instead of the launch option, the script can write the same override into the
game's Proton prefix (`compatdata/686060/pfx/user.reg`). It asks first and
leaves the prefix alone if you say no. A dry run never writes to a prefix.

## Undo an install

After a successful install the installer writes a small record inside the game
folder, `mods/.breeding-spike-installed`, listing the files it placed:
`version.dll`, `chainloader.ini`, and `mods/BreedingSpike.dll`. Uninstall only
touches a file the record lists and that still has the exact content the
installer wrote, so a file you replaced by hand is left alone.

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

- Windows: run `uninstall.bat` (double-click it).
- Linux/NixOS: run `./uninstall.sh`, which is the same uninstall.

Both wrappers only ask for confirmation, naming the game folder, and then hand
over to the installer, so uninstalling is as easy as installing. A second run is
safe, and without a terminal to ask on the Linux one stops rather than assuming
yes.

If there is no record, uninstall removes nothing and says so, naming every file
it deliberately leaves. That protects a game folder that was set up by Mewtator
or a manual Mewjector install rather than through these scripts.

`-DryRun` / `--dry-run` shows what would be restored without changing anything,
and the uninstall wrappers take it too (`uninstall.bat -DryRun`,
`./uninstall.sh --dry-run`).

The installers never remove `mod_logs/`, saves, or any other game file. Delete
`mod_logs/` by hand if you want the loader logs gone.
