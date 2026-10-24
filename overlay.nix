_: super:
builtins.removeAttrs (import ./default.nix {pkgs = super;}) [
  "default"
  "lib"
  "overlays"
  "nixosModules"
  "homeModules"
  "darwinModules"
  "flakeModules"
]
