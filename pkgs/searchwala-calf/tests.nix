# The searchwala-calf modules, evaluated: each must run the engine on its socket with the environment given to it.
# The macOS claims are checked at evaluation: nothing for darwin builds here.
{
  lib,
  runCommand,
  path,
  stdenv,
  nixDarwin ? null,
}: let
  environment.PROXY_POOL = "socks5h://[::1]:1080";

  nixos =
    (import "${path}/nixos/lib/eval-config.nix" {
      inherit (stdenv.hostPlatform) system;
      modules = [
        ../../modules/searchwala-calf/nixos.nix
        {
          system.stateVersion = "26.05";
          services.searchwala-calf = {
            enable = true;
            inherit environment;
          };
        }
      ];
    }).config;

  darwin =
    (import "${nixDarwin}/eval-config.nix" {
      inherit lib;
      modules = [
        ../../modules/searchwala-calf/darwin.nix
        {
          nixpkgs = {
            hostPlatform = "aarch64-darwin";
            source = path;
          };
          system = {
            stateVersion = 6;
            primaryUser = "calf";
          };
          services.searchwala-calf = {
            enable = true;
            inherit environment;
          };
        }
      ];
    }).config;

  checked = name: claims:
    assert lib.assertMsg (lib.all lib.id (lib.attrValues claims)) "${name}: ${lib.concatStringsSep ", " (lib.attrNames (lib.filterAttrs (_: ok: !ok) claims))}";
      runCommand name {} "touch $out";
in
  {
    nixos-module = let
      unit = nixos.systemd.services.searchwala-calf;
    in
      checked "searchwala-calf-nixos-module" {
        "runs the engine" = lib.hasSuffix "/bin/searchwala-calf" unit.serviceConfig.ExecStart;
        "on its socket" = unit.environment.LISTEN_UNIX == "/run/searchwala-calf/search.sock";
        "with the environment given" = unit.environment.PROXY_POOL == environment.PROXY_POOL;
        "hardened" = unit.serviceConfig.DynamicUser && unit.serviceConfig.ProtectSystem == "strict";
      };
  }
  // lib.optionalAttrs (nixDarwin != null) {
    darwin-module = let
      agent = darwin.launchd.user.agents.searchwala-calf;
    in
      checked "searchwala-calf-darwin-module" {
        "runs the engine" = lib.hasSuffix "/bin/searchwala-calf" agent.command;
        "on its socket" = agent.serviceConfig.EnvironmentVariables.LISTEN_UNIX == "/tmp/searchwala-calf.sock";
        "with the environment given" = agent.serviceConfig.EnvironmentVariables.PROXY_POOL == environment.PROXY_POOL;
      };
  }
