_: super:
builtins.removeAttrs (import ./default.nix {pkgs = super;}) [
  "lib"
  "overlays"
  "nixosModules"
  "homeModules"
  "darwinModules"
  "flakeModules"
]
