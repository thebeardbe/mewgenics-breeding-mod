# Patches to vendored Mewjector

The installer bundle ships a **patched** Mewjector loader (`version.dll` +
`chainloader.ini`). The official v3.4 loader hangs on some Proton/Wine launches
because it always installs its entry-point fallback.

## `EnableEPFallback` and honouring `Logging=0`

- **Upstream PR:** <https://github.com/githubuser508/mewjector/pull/6>
- **Patch:** `patches/mewjector-epfallback-and-logging.patch` (in the repository)
- **What it changes:**
  - adds the `Chainloader/EnableEPFallback` ini option (default `1`). Setting it
    to `0` skips the entry-point patch that races with game startup on some
    Proton/Wine setups.
  - makes `Chainloader/Logging=0` actually suppress the chainloader log, instead
    of opening it regardless.
- **Why it is carried here:** the fix has not landed upstream yet. The loader is
  built from the pinned Mewjector source with this patch applied (see
  `build.sh --patched`).

## What the installer does about it

The installer prefers the official loader as soon as upstream carries the fix.
On each install it reads the latest official release's `chainloader.ini`:

- if it contains `EnableEPFallback`, the official loader and ini are used;
- otherwise (or with no network, or if the download or extraction fails) the
  bundled patched loader is used.

Either way the installer prints which loader it used and why, next to the
achievements line. Pass `--bundled-loader` (`install.sh`) or `-BundledLoader`
(`install.ps1`) to force the bundled patched loader.

Mewjector is MIT-licensed; its licence text ships beside this file as
`MEWJECTOR-LICENSE.txt`.
