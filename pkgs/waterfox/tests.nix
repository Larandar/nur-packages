# The waterfox modules, evaluated: each must install a Waterfox carrying the settings given to it.
{
  lib,
  runCommand,
  path,
  stdenv,
  pkgs,
  homeManager,
}: let
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
            certificates = [
              ''
                -----BEGIN CERTIFICATE-----
                MIIBszCCAVmgAwIBAgIUTESTTESTTESTTESTTESTTESTTEQwCgYIKoZIzj0EAwIw
                -----END CERTIFICATE-----
              ''
            ];
          };
        }
      ];
    }).config;

  home =
    (import "${homeManager}/modules" {
      inherit pkgs;
      configuration = {
        imports = [../../modules/waterfox/home.nix];
        home = {
          username = "waterfox";
          homeDirectory = "/home/waterfox";
          stateVersion = "26.05";
        };
        programs.waterfox = {
          enable = true;
          policies.DisableTelemetry = true;
          profiles.default.settings."browser.startup.page" = 3;
        };
      };
    }).config;

  checked = name: claims: script:
    assert lib.assertMsg (lib.all lib.id (lib.attrValues claims)) "${name}: ${lib.concatStringsSep ", " (lib.attrNames (lib.filterAttrs (_: ok: !ok) claims))}";
      runCommand name {} ''
        ${script}
        touch $out
      '';
in {
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
}
