# programs.waterfox for Home Manager: home-manager's own Firefox-family module (profiles, settings, extensions,
# search, bookmarks, policies), as it builds programs.librewolf, over this repository's Waterfox. Install-level settings
# (chrome, newTabCommand, loginStorage, ...) go through `programs.waterfox.package = pkgs.waterfox.override { ... }`.
{
  lib,
  pkgs,
  modulesPath,
  ...
}: {
  imports = [
    (import "${modulesPath}/programs/firefox/mkFirefoxModule.nix" {
      modulePath = [
        "programs"
        "waterfox"
      ];
      name = "Waterfox";
      description = "Waterfox is a privacy-focused Firefox fork.";
      wrappedPackageName = "waterfox";
      unwrappedPackageName = "waterfox-unwrapped";
      # application.ini names the profile `Waterfox`, which Linux keeps as ~/.waterfox.
      platforms.linux.configPath = ".waterfox";
      # Required by mkFirefoxModule; this repository's Waterfox builds for x86_64-linux only.
      platforms.darwin.configPath = "Library/Application Support/Waterfox";
    })
  ];

  config.programs.waterfox.package = lib.mkDefault (import ../.. {inherit pkgs;}).waterfox;
}
