# Take nixpkgs only through `pkgs`; never import <nixpkgs> below.
{pkgs ? import (import ./nix/tamal {}).nixpkgs {}}: let
  inputs = import ./nix/tamal {bootstrap-pkgs = pkgs;};
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
    ];
  };

  example-package = pkgs.callPackage ./pkgs/example-package {};
  inherit nixtamal;
}
