# programs.waterfox for Home Manager: home-manager's own Firefox-family module (profiles, settings, extensions,
# search, bookmarks, policies), as it builds programs.librewolf, over this repository's Waterfox. Install-level settings
# (chrome, newTabCommand, loginStorage, ...) go through `programs.waterfox.package = pkgs.waterfox.override { ... }`.
# On macOS the app is Homebrew's, untouched: no package, and the policies go to the user's defaults for its bundle id.
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
      platforms.darwin = {
        configPath = "Library/Application Support/Waterfox";
        defaultsId = "net.waterfox.waterfox";
      };
    })
  ];

  config.programs.waterfox.package = lib.mkDefault (
    if pkgs.stdenv.hostPlatform.isDarwin
    then null
    else (import ../.. {inherit pkgs;}).waterfox
  );
}
