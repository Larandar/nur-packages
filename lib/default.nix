# Callers pass a package set: `default.nix` hands `{inherit pkgs;}` and the
# flake's top-level `lib` is the same shape. `lib` here is therefore nixpkgs'
# attrset, taken off it.
{pkgs}: let
  inherit (pkgs) lib;
in {
  # The Ting chrome theme's composer, palettes, stylix bridge, preferences and chrome files (pkgs/ting-chrome).
  ting = import ../pkgs/ting-chrome/lib {inherit lib;};
}
