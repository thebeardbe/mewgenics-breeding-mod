# Vendored upstream sources

Nothing upstream is committed here. `vendor/sync.sh` fetches pinned revisions
into `vendor/upstream/` (gitignored), and `build.sh` calls it automatically.

| Local path | Upstream | Revision | License |
|---|---|---|---|
| `vendor/upstream/mewjector` | https://github.com/githubuser508/mewjector | `ccdd6813cef0f51342eb74c0cecb47654f7dbeef` | MIT (Mewjector Contributors) |
| `vendor/upstream/mewui` | https://github.com/Pseudonym-Tim/mewgenics-ui-api | `fffef60696c50f0748052da8e6a1fb12dfaabbe9` | MIT (Pseudonym_Tim) |

What each provides:

- **mewjector**: the `version.dll` proxy and the `MJ_*` mod API. We build
  `version.dll` from it and include `mewjector.h` in our mod.
- **mewui** (`mewgenics-ui-api`): `mew_ui_api.c/.h`. Compiled into our mod DLL;
  it is a library, not a standalone mod. Provides scene bindings, button
  create/hook, and localized text on top of Mewjector.

Toolchain note: both use MSVC `__try`/`__except`, so neither GCC nor plain
clang/mingw will build them. We use `zig cc -target x86_64-windows-gnu
-fms-extensions`, which does. This is why the flake pins `zig`.

To bump a pin: edit `vendor/sync.sh`, run `./vendor/sync.sh`, rebuild, and
update this table.
