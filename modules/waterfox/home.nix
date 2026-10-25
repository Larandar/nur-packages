# programs.waterfox for Home Manager: home-manager's own Firefox-family module (profiles, settings, extensions,
# search, bookmarks, policies), as it builds programs.librewolf, over this repository's Waterfox. Install-level settings
# (chrome, newTabCommand, loginStorage, ...) go through `programs.waterfox.package = pkgs.waterfox.override { ... }`.
# On macOS the app is Homebrew's, untouched: no package, and the policies go to the user's defaults for its bundle id.
# A `theme` is a profile's: each profile takes the top level's unless it picks its own, and wears it as its chrome/
# files and the preferences they need; companions land in $XDG_CONFIG_HOME/<theme>/<profile>/. Policies are the
# install's, so the extensions' styles follow the top level's theme.
#
# The remote debugging interface is the system's (nixosModules.waterfox's programs.waterfox.remote: the daemon and the
# firewall rule); a Home Manager Waterfox on that host takes its settings from there. `vicinae` makes Vicinae the
# address bar over it: Ctrl+T opens the waterfox-ctl extension's web view, and `web://<text>` URIs open through the
# extension's `open` command. The extension is the host's to supply.
{
  config,
  lib,
  pkgs,
  modulesPath,
  osConfig ? null,
  ...
}: let
  themes = import ./themes.nix {inherit lib;};
  cfg = config.programs.waterfox;
  stylix = themes.stylixOf config;
  render = themes.render {
    inherit stylix;
    inherit (pkgs.stdenv.hostPlatform) isDarwin;
  };
  themed = lib.filterAttrs (_: profile: profile.theme != null) cfg.profiles;
  topTheme = render cfg;
  # The system's programs.waterfox.remote, when it is on.
  remote =
    if (osConfig.programs.waterfox.remote.enable or false)
    then osConfig.programs.waterfox.remote.settings
    else null;
  vicinae = lib.getExe cfg.vicinae.package;
  # web://<text>, percent-encoded as a URI: the text goes to the extension's `open` command, which decides what it
  # opens (an address, or a search).
  webHandler = pkgs.writers.writeNuBin "waterfox-web-open" ''
    def main [uri: string] {
      let text = $uri | str replace --regex '^(?i)web://' ''' | url decode
      let arguments = {target: $text} | to json --raw | url encode --all
      ^${vicinae} deeplink $"vicinae://launch/@larandar/waterfox-ctl/open?arguments=($arguments)"
    }
  '';
  webEntry = pkgs.makeDesktopItem {
    name = "waterfox-web";
    desktopName = "Waterfox (web://)";
    exec = "${lib.getExe webHandler} %u";
    mimeTypes = ["x-scheme-handler/web"];
    noDisplay = true;
  };
in {
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

  options.programs.waterfox =
    themes.options (config.lib ? stylix)
    // {
      vicinae = {
        enable = lib.mkEnableOption "Vicinae as Waterfox's address bar: Ctrl+T opens the waterfox-ctl web view, and web:// URIs open through it";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.vicinae;
          defaultText = lib.literalExpression "pkgs.vicinae";
          description = "The Vicinae whose CLI sends the deeplinks: the same release as the running server.";
        };
        extension = lib.mkOption {
          type = lib.types.package;
          description = "The `@larandar/waterfox-ctl` extension (viciting's `vicinae-waterfox-ctl`), installed into Vicinae.";
        };
      };
      profiles = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule ({config, ...}: let
          theme = render config;
        in {
          options = themes.inheritedOptions "programs.waterfox" cfg;
          config = lib.mkIf (config.theme != null) {
            userChrome = lib.mkDefault (pkgs.writeText "userChrome.css" theme.files."userChrome.css");
            userContent = lib.mkIf (theme.files ? "userContent.css") (lib.mkDefault (pkgs.writeText "userContent.css" theme.files."userContent.css"));
            settings = lib.mapAttrs (_: lib.mkDefault) theme.preferences;
          };
        }));
      };
    };

  config = lib.mkMerge [
    {
      programs.waterfox.package = lib.mkDefault (
        if pkgs.stdenv.hostPlatform.isDarwin
        then null
        else
          (import ../.. {inherit pkgs;}).waterfox.override {
            inherit remote;
            newTabCommand =
              if cfg.vicinae.enable
              then [vicinae "deeplink" "vicinae://launch/@larandar/waterfox-ctl/web"]
              else null;
          }
      );
    }
    (lib.mkIf (cfg.enable && cfg.vicinae.enable) {
      assertions = [
        {
          assertion = remote != null;
          message = "programs.waterfox.vicinae needs the system's programs.waterfox.remote: the extension drives Waterfox over its Varlink socket.";
        }
      ];
      home.packages = [webHandler webEntry];
      xdg.mimeApps.defaultApplications."x-scheme-handler/web" = "waterfox-web.desktop";
      programs.vicinae.extensions = [cfg.vicinae.extension];
    })
    (lib.mkIf (cfg.enable && cfg.theme != null) {
      assertions = themes.assertions stylix cfg;
      programs.waterfox.policies = topTheme.policies;
    })
    (lib.mkIf (cfg.enable && themed != {}) {
      assertions = lib.concatLists (lib.mapAttrsToList (_: themes.assertions stylix) themed);
      # userChrome.css and userContent.css are the profile's own options; the rest of chrome/ goes beside them.
      home.file = lib.mkMerge (lib.mapAttrsToList (_: profile:
        lib.mapAttrs' (name: text: lib.nameValuePair "${cfg.profilesPath}/${profile.path}/chrome/${name}" {inherit text;})
        (removeAttrs (render profile).files ["userChrome.css" "userContent.css"]))
      themed);
      xdg.configFile = lib.mkMerge (lib.mapAttrsToList (name: profile:
        lib.mapAttrs' (file: text: lib.nameValuePair "${profile.theme}/${name}/${file}" {inherit text;}) (render profile).companions)
      themed);
    })
  ];
}
