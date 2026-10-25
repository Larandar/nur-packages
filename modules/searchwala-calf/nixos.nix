# services.searchwala-calf for NixOS: the door's engine as a hardened systemd unit on a unix socket. The page
# (`package.page`) and the vhost in front of both are the host's to serve; this module only runs the engine.
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
      default = "/run/searchwala-calf/search.sock";
      readOnly = true;
      description = "The unix socket the engine listens on (mode 0666); proxy `/search` and `/health` to it, `/search` unbuffered (`flush_interval -1` in Caddy): it streams NDJSON.";
    };
    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        PROXY_POOL = "socks5h://[::1]:1080";
        CALF_LLM_PROVIDER = "openai";
        CALF_LLM_MODEL = "gpt-4o-mini";
      };
      description = "Extra environment: `PROXY_POOL` (socks5h:// or http:// proxies, comma-separated) for the engines, `STEALTH_MODE`, and the CALF_LLM_* variables, without which synthesis stays off. Keys go in `environmentFile`, not here.";
    };
    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "A file of secrets (e.g. CALF_LLM_API_KEY), read by systemd, never in the store.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.searchwala-calf = {
      description = "searchwala-calf search door (unix socket)";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      environment =
        {
          LISTEN_UNIX = cfg.socket;
          RUST_LOG = "info";
        }
        // cfg.environment;
      serviceConfig = {
        ExecStart = lib.getExe cfg.package;
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        RuntimeDirectory = "searchwala-calf";
        RuntimeDirectoryMode = "0755";
        DynamicUser = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
