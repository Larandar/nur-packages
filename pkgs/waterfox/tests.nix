# The waterfox modules, evaluated: each must install a Waterfox carrying the settings given to it, or on macOS leave
# Homebrew's app alone and give the settings as defaults. The macOS claims are checked at evaluation: nothing for
# darwin builds here.
{
  lib,
  runCommand,
  path,
  stdenv,
  pkgs,
  homeManager,
  nixDarwin ? null,
}: let
  certificate = ''
    -----BEGIN CERTIFICATE-----
    MIIBszCCAVmgAwIBAgIUTESTTESTTESTTESTTESTTESTTEQwCgYIKoZIzj0EAwIw
    -----END CERTIFICATE-----
  '';

  nixosWith = extra:
    (import "${path}/nixos/lib/eval-config.nix" {
      inherit (stdenv.hostPlatform) system;
      modules = [
        ../../modules/waterfox/nixos.nix
        extra
        {
          system.stateVersion = "26.05";
          programs.waterfox = {
            enable = true;
            preferences = {
              "browser.startup.page" = 3;
              "general.smoothScroll" = {
                value = false;
                status = "default";
              };
            };
            policies.DisableTelemetry = true;
            certificates = [certificate];
          };
        }
      ];
    }).config;

  nixos = nixosWith {};
  nixosTing = nixosWith {programs.waterfox.theme = "ting";};

  homeWith = extra: pkgs: homeDirectory:
    (import "${homeManager}/modules" {
      inherit pkgs;
      configuration = {
        imports = [
          ../../modules/waterfox/home.nix
          extra
        ];
        home = {
          username = "waterfox";
          inherit homeDirectory;
          stateVersion = "26.05";
        };
        programs.waterfox = {
          enable = true;
          policies.DisableTelemetry = true;
          profiles.default.settings."browser.startup.page" = 3;
        };
      };
    }).config;

  homeOn = homeWith {};
  home = homeOn pkgs "/home/waterfox";
  # The top level picks Ting; the `plain` profile keeps Waterfox's own look.
  homeTing =
    homeWith {
      programs.waterfox = {
        theme = "ting";
        themes.ting.paletteName = "midnight";
        profiles.plain = {
          id = 1;
          theme = null;
        };
      };
    }
    pkgs "/home/waterfox";

  darwinPkgs = import path {system = "aarch64-darwin";};

  darwin =
    (import "${nixDarwin}/eval-config.nix" {
      inherit lib;
      modules = [
        ../../modules/waterfox/darwin.nix
        {
          nixpkgs = {
            hostPlatform = "aarch64-darwin";
            source = path;
          };
          system = {
            stateVersion = 6;
            primaryUser = "waterfox";
          };
          homebrew.enable = true;
          programs.waterfox = {
            enable = true;
            preferences."browser.startup.page" = 3;
            policies.DisableTelemetry = true;
            certificates = [certificate];
          };
        }
      ];
    }).config;

  checked = name: claims: script:
    assert lib.assertMsg (lib.all lib.id (lib.attrValues claims)) "${name}: ${lib.concatStringsSep ", " (lib.attrNames (lib.filterAttrs (_: ok: !ok) claims))}";
      runCommand name {} ''
        ${script}
        touch $out
      '';
in
  {
    nixos-module = let
      package = nixos.programs.waterfox.package;
    in
      checked "waterfox-nixos-module" {
        "installed system-wide" = lib.elem package nixos.environment.systemPackages;
      } ''
        grep -qF 'lockPref("browser.startup.page", 3);' ${package}/lib/waterfox/waterfox.cfg
        grep -qF 'defaultPref("general.smoothScroll", false);' ${package}/lib/waterfox/waterfox.cfg
        grep -qF '"DisableTelemetry":true' ${package}/lib/waterfox/distribution/policies.json
        grep -qF '"Certificates":{"Install":["/nix/store/' ${package}/lib/waterfox/distribution/policies.json
      '';
    home-module = let
      package = home.programs.waterfox.finalPackage;
    in
      checked "waterfox-home-module" {
        "installed for the user" = lib.elem package home.home.packages;
        "a profile under ~/.waterfox" = home.home.file ? ".waterfox/default/user.js";
      } ''
        grep -qF '"DisableTelemetry":true' ${package}/lib/waterfox/distribution/policies.json
        grep -qF 'user_pref("browser.startup.page", 3);' ${home.home.file.".waterfox/default/user.js".source}
      '';
    nixos-module-ting = let
      package = nixosTing.programs.waterfox.package;
    in
      checked "waterfox-nixos-module-ting" {
        "Sidebery's companion in /etc" = nixosTing.environment.etc ? "ting/sidebery.css";
        "no chrome without a theme" = nixos.programs.waterfox.chrome == null;
        "Dark Reader left to its owner" = !(nixosTing.environment.etc ? "ting/darkreader.json");
      } ''
        chrome=$(sed -n 's|.*newURI("file://\(/nix/store/[^/]*\)/".*|\1|p' ${package}/lib/waterfox/waterfox.cfg)
        test -s "$chrome/userChrome.css"
        grep -qF '@import url("palette.css")' "$chrome/userChrome.css"
        test -s "$chrome/palette.css"
        grep -qF 'lockPref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' ${package}/lib/waterfox/waterfox.cfg
        grep -qF '"3rdparty":{"Extensions":{"{3c078156-979c-498b-8990-85f7987dd929}":{"groupCSS":' ${package}/lib/waterfox/distribution/policies.json
      '';
    home-module-ting = let
      file = homeTing.home.file;
    in
      checked "waterfox-home-module-ting" {
        "the default profile's chrome" = file ? ".waterfox/default/chrome/userChrome.css" && file ? ".waterfox/default/chrome/palette.css";
        "the plain profile has no theme preferences" = !(homeTing.programs.waterfox.profiles.plain.settings ? "toolkit.legacyUserProfileCustomizations.stylesheets");
        "the plain profile has no chrome" = !(file ? ".waterfox/plain/chrome/userChrome.css" || file ? ".waterfox/plain/chrome/palette.css");
        "Sidebery's companion per profile" = homeTing.xdg.configFile ? "ting/default/sidebery.css";
        "Sidebery's styles as managed storage" = homeTing.programs.waterfox.policies."3rdparty".Extensions."{3c078156-979c-498b-8990-85f7987dd929}" ? sidebarCSS;
        "no policy without a theme" = !(home.programs.waterfox.policies ? "3rdparty");
        "no chrome without a theme" = !(home.home.file ? ".waterfox/default/chrome/userChrome.css");
      } ''
        grep -qF '@import url("palette.css")' ${file.".waterfox/default/chrome/userChrome.css".source}
        grep -qF -- '--vt-accent-rgb: 34 211 238;' ${file.".waterfox/default/chrome/palette.css".source}
        grep -qF 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' ${file.".waterfox/default/user.js".source}
      '';
    home-module-darwin = let
      darwinHome = homeOn darwinPkgs "/Users/waterfox";
    in
      checked "waterfox-home-module-darwin" {
        "no package: Homebrew's app" = darwinHome.programs.waterfox.finalPackage == null;
        "policies in the user's defaults" =
          darwinHome.targets.darwin.defaults."net.waterfox.waterfox"
          == {
            EnterprisePoliciesEnabled = true;
            DisableTelemetry = true;
          };
        "a profile under Application Support" = darwinHome.home.file ? "Library/Application Support/Waterfox/Profiles/default/user.js";
      } "";
  }
  // lib.optionalAttrs (nixDarwin != null) {
    darwin-module = let
      domain = darwin.system.defaults.CustomSystemPreferences."/Library/Preferences/net.waterfox.waterfox";
    in
      checked "waterfox-darwin-module" {
        "the cask installed" = lib.any (cask: cask.name == "waterfox") darwin.homebrew.casks;
        "policies enabled" = domain.EnterprisePoliciesEnabled;
        "policies given" = domain.DisableTelemetry;
        "preferences as the Preferences policy" =
          domain.Preferences."browser.startup.page"
          == {
            Value = 3;
            Status = "locked";
          };
        "certificates from the store" = lib.hasPrefix "/nix/store/" (builtins.head domain.Certificates.Install);
      } "";
  }
