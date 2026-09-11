{
  description = "Mewgenics Breeding Mod — in-game bridge for the Mewgenics Breeding Overlay (research phase)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig          # cross-compiles Windows PE with MSVC SEH (__try)
              pkgs.python3      # vendor sync + PE tooling
              pkgs.binutils     # objdump for inspecting the game exe
              pkgs.git
            ];
            shellHook = ''
              echo "Mewgenics breeding mod dev shell"
              echo "  ./build.sh              build version.dll + BreedingSpike.dll into dist/"
              echo "  ./tools/smoke/run_smoke.sh   Wine smoke test (needs wine64)"
            '';
          };
        });
    };
}
