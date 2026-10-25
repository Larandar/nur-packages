# programs.waterfox for NixOS: Waterfox with its settings baked into the install, for every user. A `theme` becomes the
# install's `chrome` and the preferences it needs; its companions land in /etc/<theme>/.
{
  config,
  lib,
  pkgs,
  ...
}: let
  common = import ./common.nix {inherit lib;};
  themes = import ./themes.nix {inherit lib;};
  cfg = config.programs.waterfox;
  stylix = themes.stylixOf config;
  theme = themes.render {inherit stylix;} cfg;
in {
  options.programs.waterfox = common.options pkgs // themes.options (config.lib ? stylix);

  config = lib.mkMerge [
    {programs.waterfox.package = common.package pkgs cfg;}
    (lib.mkIf cfg.enable {environment.systemPackages = [cfg.package];})
    (lib.mkIf (cfg.theme != null) {
      assertions = themes.assertions stylix cfg;
      programs.waterfox = {
        chrome = lib.mkDefault (themes.chromeDirectory pkgs theme.files);
        preferences = lib.mapAttrs (_: lib.mkDefault) theme.preferences;
      };
      environment.etc = lib.mapAttrs' (name: text: lib.nameValuePair "${cfg.theme}/${name}" {inherit text;}) theme.companions;
    })
  ];
}
