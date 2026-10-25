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

  nixos =
    (import "${path}/nixos/lib/eval-config.nix" {
      inherit (stdenv.hostPlatform) system;
      modules = [
        ../../modules/waterfox/nixos.nix
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

  homeOn = pkgs: homeDirectory:
    (import "${homeManager}/modules" {
      inherit pkgs;
      configuration = {
        imports = [../../modules/waterfox/home.nix];
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

  home = homeOn pkgs "/home/waterfox";

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
