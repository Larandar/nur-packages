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

  engram = pins.package "engram" ./pkgs/engram {};
  kasetto = pins.package "kasetto" ./pkgs/kasetto {};
  phrog = pins.package "phrog" ./pkgs/phrog {};
  neocursor = pins.package "neocursor" ./pkgs/neocursor {};
  snix = pins.package "snix" ./pkgs/snix {};
  nu-plugin-ws = pins.package "nu-plugin-ws" ./pkgs/nu-plugin-ws {};
  nu-plugin-mongo = pins.package "nu-plugin-mongo" ./pkgs/nu-plugin-mongo {};
  celld = pins.package "celld" ./pkgs/celld {
    rustyV8 = inputs.celld-rusty-v8;
    rustyV8Version = (pkgs.lib.importJSON ./nix/tamal/lock.json).i.celld-rusty-v8.fv;
  };
}
