# Dev shell for the Mewgenics breeding mod.
#
#   nix-shell          # zig + python3 + binutils + git
#
# Wine is intentionally not included: it is a large closure and only needed for
# the smoke test, which can be run with `nix shell nixpkgs#wine64` instead.

{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    zig
    python3
    binutils
    patch
    git
  ];

  shellHook = ''
    echo "Mewgenics breeding mod dev shell"
    echo "  ./build.sh                   build version.dll + BreedingSpike.dll into dist/"
    echo "  ./tools/smoke/run_smoke.sh   Wine smoke test (needs wine64)"
  '';
}
