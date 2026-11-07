# Take nixpkgs only through `pkgs`; never import <nixpkgs> below.
{pkgs ? import (import ./nix/tamal {}).nixpkgs {}}: let
  pins = import ./nix/pins.nix {inherit pkgs;};
  inherit (pins) inputs;
  waterfox = pins.package "waterfox" ./pkgs/waterfox {
    homeManager = inputs.home-manager;
    nixDarwin = inputs.nix-darwin;
  };
  iets = (import "${inputs.iets}/nix/flake-compat.nix" {src = inputs.iets;}).defaultNix.packages.${pkgs.stdenv.hostPlatform.system}.default;
  thinkrail = let
    input =
      {aarch64-darwin = "thinkrail-darwin-arm64";}.${pkgs.stdenv.hostPlatform.system} or "thinkrail";
  in
    pkgs.callPackage ./pkgs/thinkrail {
      src = inputs.${input};
      version = pkgs.lib.removePrefix "v" (pkgs.lib.importJSON ./nix/tamal/lock.json).i.${input}.fv;
    };
  nixtamal = pkgs.callPackage ./pkgs/nixtamal {
    inherit (pkgs) nixtamal;
    src = inputs.nixtamal;
  };
in {
  # Reserved names: overlay.nix, and through it ci.nix, excludes them from the package set.
  lib = import ./lib {inherit pkgs;};
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
      # Fast evaluation and builds for `toolkit check`; numtide packages it, through its flake.
      iets
    ];
  };

  example-package = pkgs.callPackage ./pkgs/example-package {};
  inherit nixtamal;

  engram = pins.package "engram" ./pkgs/engram {};
  kasetto = pins.package "kasetto" ./pkgs/kasetto {};
  phrog = pins.package "phrog" ./pkgs/phrog {};
  neocursor = pins.package "neocursor" ./pkgs/neocursor {};
  snix = pins.package "snix" ./pkgs/snix {};
  inherit thinkrail waterfox;
  waterfox-unwrapped = waterfox.unwrapped;
  waterfox-remote = pkgs.callPackage ./pkgs/waterfox/remote {};
  ting-chrome = pkgs.callPackage ./pkgs/ting-chrome/package.nix {};
  searchwala-calf = pins.package "searchwala-calf" ./pkgs/searchwala-calf {nixDarwin = inputs.nix-darwin;};
  vproxy = pins.package "vproxy" ./pkgs/vproxy {};
  nu-plugin-ws = pins.package "nu-plugin-ws" ./pkgs/nu-plugin-ws {};
  nu-plugin-mongo = pins.package "nu-plugin-mongo" ./pkgs/nu-plugin-mongo {};
  celld = pins.package "celld" ./pkgs/celld {
    rustyV8 = inputs.celld-rusty-v8;
    rustyV8Version = (pkgs.lib.importJSON ./nix/tamal/lock.json).i.celld-rusty-v8.fv;
  };
}
