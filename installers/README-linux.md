# Mewgenics Breeding Mod (Linux and NixOS, Proton)

The in-game bridge for the Mewgenics Breeding Overlay: a Mewjector loader and
our mod DLL are placed in the game folder so the overlay can follow the cat you
select.

## Install

1. Unpack the whole zip and keep the folder together.
2. Run `./install.sh` in a terminal.
3. Set this Steam launch option, in
   `Steam -> Mewgenics -> Properties -> Launch Options`:

   ```
   WINEDLLOVERRIDES="version=n,b" %command%
   ```

4. Start Mewgenics normally.

## Uninstall

Run `./uninstall.sh`. It asks for confirmation first and names the game folder
it is about to clean.

## More

`docs/HOW-IT-WORKS.md` explains the loader, the three files, dry runs,
re-installing, and uninstalling in detail. `docs/PATCHES.md` covers the loader
patch and the upstream PR, and `docs/MEWJECTOR-LICENSE.txt` is Mewjector's MIT
licence.
