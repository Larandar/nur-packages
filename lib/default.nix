# Callers pass a package set: `default.nix` hands `{inherit pkgs;}` and the
# flake's top-level `lib` is the same shape. `lib` here is therefore nixpkgs'
# attrset, taken off it.
{pkgs}: let
  inherit (pkgs) lib;
in {
  # The Ting chrome theme's composer, palettes, stylix bridge, preferences and chrome files (pkgs/ting-chrome).
  ting = import ../pkgs/ting-chrome/lib {inherit lib;};

  # Aspect trees: a consumer's `modules/aspects/` is a registry whose keys come
  # from file paths. Packaging, not policy — which aspects exist stays the
  # consumer's, and this only phrases them as the services that consumer binds.
  # Consume it as `nur-packages.lib.aspects.mkModules {src = ./modules/aspects;}`
  # with `lib` from the same nixpkgs, since it is pure path arithmetic.
  aspects = import ./aspects {inherit lib;};

  # `loadTree` is `lib.aspects.mkModules` under the name the aspect tree grew
  # up with; the loader's output shape is a flake-parts-free attrset either way.
  loadTree = import ./aspects {inherit lib;};
}
