# services.searchwala-calf for nix-darwin: the door's engine as a launchd user agent. /tmp is the one directory both a
# user agent and a system web server reach; the engine chmods its socket 0666 on bind.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.searchwala-calf;
in {
  options.services.searchwala-calf = {
    enable = lib.mkEnableOption "searchwala-calf, a lite SearchWala search door";
    package = lib.mkOption {
      type = lib.types.package;
      default = (import ../.. {inherit pkgs;}).searchwala-calf;
      defaultText = lib.literalExpression "nur-packages.searchwala-calf";
      description = "The engine. `package.page` is the start page tree.";
    };
    socket = lib.mkOption {
      type = lib.types.str;
      default = "/tmp/searchwala-calf.sock";
      readOnly = true;
      description = "The unix socket the engine listens on (mode 0666).";
    };
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra environment (PROXY_POOL, CALF_LLM_* and friends). launchd has no secret file: keys placed here land in the store.";
    };
  };

  config = lib.mkIf cfg.enable {
    # `command`, never `serviceConfig.ProgramArguments`: nix-darwin renders `command` behind /bin/wait4path, so the
    # agent cannot exec before the store is mounted at boot and be parked by launchd.
    launchd.user.agents.searchwala-calf = {
      command = lib.getExe cfg.package;
      serviceConfig = {
        EnvironmentVariables =
          {
            LISTEN_UNIX = cfg.socket;
            RUST_LOG = "info";
          }
          // cfg.environment;
        KeepAlive = true;
        RunAtLoad = true;
      };
    };
  };
}
