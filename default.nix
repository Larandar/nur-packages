# Take nixpkgs only through `pkgs`; never import <nixpkgs> below.
{pkgs ? import (import ./nix/tamal {}).nixpkgs {}}: let
  pins = import ./nix/pins.nix {inherit pkgs;};
  inherit (pins) inputs;
  nixtamal = pkgs.callPackage ./pkgs/nixtamal {
    inherit (pkgs) nixtamal;
    src = inputs.nixtamal;
  };
in {
  # Reserved names: overlay.nix, and through it ci.nix, excludes them from the package set.
  lib = import ./lib {inherit pkgs;};
  nixosModules = import ./nixos-modules;
  overlays = import ./overlays;
  default.devShell = pkgs.mkShell {
    packages = [
      (nixtamal.override {
        enabledPatches = ["shell"];
        packages = [pkgs.nushell];
      }).bin
      # `nix/fresh.nu` reads tags with `git ls-remote`.
      pkgs.git
      # Syntax-aware conflict resolution: `jj resolve --tool mergiraf`.
      pkgs.mergiraf
    ];
  };

  example-package = pkgs.callPackage ./pkgs/example-package {};
  inherit nixtamal;
}
