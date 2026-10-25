# programs.waterfox for NixOS: Waterfox with its settings baked into the install, for every user.
{
  config,
  lib,
  pkgs,
  ...
}: let
  common = import ./common.nix {inherit lib;};
  cfg = config.programs.waterfox;
in {
  options.programs.waterfox = common.options pkgs;

  config = lib.mkMerge [
    {programs.waterfox.package = common.package pkgs cfg;}
    (lib.mkIf cfg.enable {environment.systemPackages = [cfg.package];})
  ];
}
