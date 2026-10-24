# Take nixpkgs only through `pkgs`; never import <nixpkgs> below.
{pkgs ? import <nixpkgs> {}}: {
  # Reserved names: overlay.nix, and through it ci.nix, excludes them from the package set.
  lib = import ./lib {inherit pkgs;};
  nixosModules = import ./nixos-modules;
  overlays = import ./overlays;

  example-package = pkgs.callPackage ./pkgs/example-package {};
}
