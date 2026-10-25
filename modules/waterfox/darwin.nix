# programs.waterfox for nix-darwin: Homebrew's Waterfox, left as the cask installs it, with every setting given as
# policies in the app's system-wide defaults (/Library/Preferences/<defaultsId>.plist), which Waterfox reads at start.
# Settings that need the Linux wrapper (chrome, newTabCommand, loginStorage, ...) do not exist here. `homebrew.enable`
# stays the host's choice: without it, nix-darwin installs no cask.
{
  config,
  lib,
  pkgs,
  ...
}: let
  common = import ./common.nix {inherit lib;};
  cfg = config.programs.waterfox;
in {
  options.programs.waterfox =
    common.settingsOptions
    // {
      enable = lib.mkEnableOption "Waterfox, installed by Homebrew";
      cask = lib.mkOption {
        type = lib.types.str;
        default = "waterfox";
        description = "The Homebrew cask that installs Waterfox.";
      };
      defaultsId = lib.mkOption {
        type = lib.types.str;
        default = "net.waterfox.waterfox";
        description = "The app's bundle identifier, whose defaults domain carries the policies.";
      };
    };

  config = lib.mkIf cfg.enable {
    homebrew.casks = [cfg.cask];
    # nix-darwin writes these keys and never deletes them: a policy removed here stays until the plist is cleared.
    system.defaults.CustomSystemPreferences."/Library/Preferences/${cfg.defaultsId}" =
      {EnterprisePoliciesEnabled = true;}
      // common.allPolicies pkgs cfg;
  };
}
