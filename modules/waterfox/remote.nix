# programs.waterfox.remote: the browser's remote debugging interface on
# loopback, and ONE waterfox-remote daemon per listed user, as a user service,
# serving every profile over standard IPC: Varlink (`ad.lar.WaterfoxRemote`)
# on varlink.sock, and D-Bus (`ad.lar.WaterfoxRemote1`, an object per
# profile) on the session bus. With `mcp.enable` it also serves MCP on
# mcp.sock (streamable HTTP; `waterfox-remote mcp` bridges it to stdio).
#
# PROFILES ARE FOUND, NOT LISTED. The wrapper records the port it chose for
# each profile it starts (/run/user/<uid>/waterfox-remote/<profile>.port);
# the daemon adopts every profile that appears, so one created while it runs
# is served too. Only users listed in `users` get the interface at all; each
# owns `rangeSize` loopback ports from its base, one per running profile.
# The runtime directory is the user's alone (mode 0700).
#
# THE MCP POLICY IS NIX'S: the root `mcp` settings are what every enabled
# profile inherits, `mcp.profiles.<name>` deep-merges a profile's own on top
# (a list it sets replaces the root's), and the result is a read-only store
# file neither the browser nor the agent can edit. A profile Nix does not
# name is invisible to MCP unless `mcp.newProfiles`. The policy restrains
# MCP clients only; a process running as the user can still reach Varlink or
# the BiDi port directly.
#
# THE PORT IS THE WEAK END, so the firewall closes it. Waterfox speaks BiDi
# over TCP only and BiDi has no authentication: anything that reaches the
# port drives the browser. Every user's range gets an output rule refusing
# loopback connections to it from any other user (root excepted: root is
# the machine). What the rule cannot stop: another user BINDING a port in
# your range first. The daemon would then talk to a stranger's listener;
# keep ranges away from ports other users' services take.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.waterfox.remote;
  capabilities = [
    "tabs"
    "read_page"
    "focus"
    "open"
    "search"
    "dns_status"
    "dns_query"
    "dns_blocking"
    "dns_refresh"
  ];
  rootPolicy = {
    inherit (cfg.mcp) tools sites;
  };
  # Deep merge: what a profile sets wins, attribute by attribute; a list is
  # one value, so a profile's `tools` replaces the root's.
  profilePolicy = override:
    lib.recursiveUpdate rootPolicy (
      lib.filterAttrsRecursive (_: v: v != null) (removeAttrs override ["enable"])
    );
  policies =
    lib.mapAttrs (
      _: override:
        if override.enable
        then profilePolicy override
        else {tools = [];}
    )
    cfg.mcp.profiles
    // lib.optionalAttrs cfg.mcp.newProfiles {"*" = rootPolicy;};
  policyFile = pkgs.writeText "waterfox-remote-mcp.json" (builtins.toJSON {profiles = policies;});
  visible = lib.filterAttrs (_: p: p.tools != []) policies;
  ranges =
    lib.mapAttrsToList (user: base: {
      inherit user base;
      last = base + cfg.rangeSize - 1;
    })
    cfg.users;
  overlapping =
    lib.filter
    (
      pair: let
        a = builtins.elemAt pair 0;
        b = builtins.elemAt pair 1;
      in
        a.user < b.user && a.base <= b.last && b.base <= a.last
    )
    (
      map
      (p: [
        p.x
        p.y
      ])
      (
        lib.cartesianProduct {
          x = ranges;
          y = ranges;
        }
      )
    );
  # Numeric: nftables checks the ruleset at build time, in a sandbox where
  # no user name resolves.
  uidOf = user: config.users.users.${user}.uid or null;
  nftRules =
    lib.concatMapStrings (r: ''
      oifname "lo" tcp dport ${toString r.base}-${toString r.last} meta skuid != { ${toString (uidOf r.user)}, 0 } reject with tcp reset
    '')
    ranges;
  # Both families: the browser's "localhost" may be ::1 as well.
  iptablesRules = verb:
    lib.concatMapStrings (
      r:
        lib.concatMapStrings
        (tool: ''
          ${tool} ${verb} OUTPUT -o lo -p tcp --dport ${toString r.base}:${toString r.last} -m owner ! --uid-owner ${r.user} -m owner ! --uid-owner 0 -j REJECT --reject-with tcp-reset${
            lib.optionalString (verb == "-D") " 2>/dev/null || true"
          }
        '')
        [
          "iptables"
          "ip6tables"
        ]
    )
    ranges;
in {
  options.programs.waterfox.remote = {
    enable = lib.mkEnableOption "the remote debugging interface and the waterfox-remote launcher bridge";
    users = lib.mkOption {
      type = lib.types.attrsOf lib.types.port;
      default = {};
      example = {
        alice = 9300;
      };
      description = "Users who get the interface, each with the base of its loopback port range. Unlisted users' browsers start without it.";
    };
    rangeSize = lib.mkOption {
      type = lib.types.ints.between 1 100;
      default = 10;
      description = "Ports per user: how many profiles can run with the interface at once.";
    };
    mcp = {
      enable = lib.mkEnableOption "MCP on mcp.sock (and `waterfox-remote mcp` on stdio), cut to the policy below";
      tools = lib.mkOption {
        type = lib.types.listOf (lib.types.enum capabilities);
        default = [
          "tabs"
          "read_page"
        ];
        description = ''
          Capabilities every enabled profile inherits; any other is not listed
          at all, as tool or resource. `tabs`/`read_page`: the browser://
          resources and the same reads as tools; `focus`/`open`: act on the
          browser; `search`: the search door (needs `searchSocket`);
          `dns_status` (resource), `dns_query`: read the resolver;
          `dns_blocking`, `dns_refresh`: act on it (need `blockyUrl`). The
          default reads the browser, never acts.
        '';
      };
      sites = {
        allow = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = ["*"];
          example = [
            "*.vegr"
            "docs.rs"
          ];
          description = "Host patterns (`*` = any run of characters) a call may touch. Pages without a host (about:, data:) pass only a bare `*`.";
        };
        deny = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          example = ["mail.*"];
          description = "Host patterns no call may touch; wins over `allow`. Denied tabs are left out of `tabs`, denied results out of `search`.";
        };
      };
      newProfiles = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether a profile not named in `mcp.profiles` (one created later included) gets the root policy. Off: it stays invisible to MCP until Nix names it.";
      };
      profiles = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "false: the profile is invisible to MCP, whatever the root says.";
              };
              tools = lib.mkOption {
                type = lib.types.nullOr (lib.types.listOf (lib.types.enum capabilities));
                default = null;
                description = "Replaces the root's `tools`; null inherits them.";
              };
              sites = {
                allow = lib.mkOption {
                  type = lib.types.nullOr (lib.types.listOf lib.types.str);
                  default = null;
                  description = "Replaces the root's `sites.allow`; null inherits it.";
                };
                deny = lib.mkOption {
                  type = lib.types.nullOr (lib.types.listOf lib.types.str);
                  default = null;
                  description = "Replaces the root's `sites.deny`; null inherits it.";
                };
              };
            };
          }
        );
        default = {};
        example = {
          work.tools = [
            "tabs"
            "read_page"
            "search"
          ];
          banking.enable = false;
        };
        description = "Per-profile overrides, deep-merged onto the root settings. Names are [A-Za-z0-9_-]; `default` is a browser started without -P/--profile.";
      };
    };
    searchSocket = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default =
        if lib.attrByPath ["services" "searchwala-calf" "enable"] false config
        then config.services.searchwala-calf.socket
        else null;
      defaultText = lib.literalMD "the searchwala-calf socket, when that service is enabled";
      description = "The search door the MCP side lends out (`search`) and parses pages with (`read_page` as markdown or json). null: pages come back as text only.";
    };
    blockyUrl = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default =
        if config.services.blocky.enable
        then let
          http = config.services.blocky.settings.ports.http or null;
        in
          if http == null
          then null
          else if builtins.isInt http
          then "http://127.0.0.1:${toString http}"
          else "http://${http}"
        else null;
      defaultText = lib.literalMD "blocky's HTTP listener, when blocky is enabled";
      description = "blocky's HTTP API, for the `dns_*` capabilities.";
    };
    dbus = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Also serve `ad.lar.WaterfoxRemote1` on the session bus (an object per profile: Tabs, Focus, Open, the LauncherQuery signal). Varlink on varlink.sock is always served.";
    };
    browserCommand = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "${pkgs.systemd}/bin/systemd-run"
        "--user"
        "--scope"
        "--collect"
        "--quiet"
        "--"
        (lib.getExe config.programs.waterfox.package)
      ];
      defaultText = lib.literalMD "this Waterfox, in its own transient systemd scope";
      description = "How `Open` starts a profile whose browser is not running; `-P <profile>` and `--headless` are appended. Its own scope keeps the browser alive when the daemon restarts. `[ ]`: `Open` on a closed profile fails.";
    };
    launcherAlias = lib.mkOption {
      type = lib.types.str;
      default = "@l";
      description = "Search alias whose queries go to `launcher` instead of the web.";
    };
    launcher = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [
        "fuzzel"
        "--dmenu"
      ];
      description = "Launcher command; the query is appended as its last argument, the profile is in WATERFOX_REMOTE_PROFILE. Empty: the alias is intercepted and dropped.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = (import ../.. {inherit pkgs;}).waterfox-remote;
      defaultText = lib.literalExpression "nur-packages.waterfox-remote";
      description = "The daemon.";
    };
    settings = lib.mkOption {
      type = lib.types.attrs;
      readOnly = true;
      description = "What the wrapper takes as `remote`: the users, their ranges and the launcher alias. A Home Manager Waterfox on this host takes it from here.";
    };
  };

  config = lib.mkMerge [
    {programs.waterfox.remote.settings = {inherit (cfg) users rangeSize launcherAlias;};}
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = lib.all (n: builtins.match "[A-Za-z0-9_-]+" n != null) (lib.attrNames cfg.mcp.profiles);
          message = "programs.waterfox.remote.mcp.profiles: names must be [A-Za-z0-9_-]+ (the wrapper maps anything else to `_`).";
        }
        {
          assertion = cfg.users != {};
          message = "programs.waterfox.remote.users is empty: nobody would get the interface.";
        }
        {
          assertion = overlapping == [];
          message = "programs.waterfox.remote.users: port ranges overlap (${
            lib.concatMapStringsSep ", " (
              p: "${(builtins.elemAt p 0).user}/${(builtins.elemAt p 1).user}"
            )
            overlapping
          }).";
        }
        {
          assertion =
            !config.networking.nftables.enable || lib.all (user: uidOf user != null) (lib.attrNames cfg.users);
          message = "programs.waterfox.remote: with nftables, every user in `users` needs a fixed users.users.<name>.uid (the ruleset is checked where names do not resolve).";
        }
        {
          assertion = config.networking.firewall.enable || config.networking.nftables.enable;
          message = "programs.waterfox.remote needs the firewall (iptables or nftables) to refuse other users' connections to each range.";
        }
      ];
      warnings =
        lib.optionals cfg.mcp.enable (
          lib.mapAttrsToList (
            profile: p: "programs.waterfox.remote.mcp: an agent on mcp.sock reads${
              lib.optionalString (lib.elem "open" p.tools || lib.elem "focus" p.tools) " and drives"
            } ${
              if profile == "*"
              then "every logged-in profile not named"
              else "the logged-in ${profile} profile"
            } (capabilities: ${lib.concatStringsSep ", " p.tools}; sites: ${lib.concatStringsSep ", " p.sites.allow}${
              lib.optionalString (p.sites.deny != []) " minus ${lib.concatStringsSep ", " p.sites.deny}"
            })."
          )
          visible
        )
        ++ [
          ''
            programs.waterfox.remote: Waterfox listens for WebDriver BiDi on
            loopback for ${lib.concatStringsSep ", " (lib.attrNames cfg.users)}. Other users are
            refused by the firewall; root, and any process running as that user,
            can still drive the browser, its tabs, cookies and storage.
          ''
        ];
      environment.systemPackages = [cfg.package];

      networking.nftables.tables.waterfox-remote = lib.mkIf config.networking.nftables.enable {
        family = "inet";
        content = ''
          chain output {
            type filter hook output priority filter; policy accept;
            ${nftRules}
          }
        '';
      };
      networking.firewall.extraCommands = lib.mkIf (!config.networking.nftables.enable) (
        iptablesRules "-A"
      );
      networking.firewall.extraStopCommands = lib.mkIf (!config.networking.nftables.enable) (
        iptablesRules "-D"
      );

      systemd.user.services.waterfox-remote = {
        description = "waterfox-remote: every Waterfox profile's BiDi session, for the launcher and agents";
        wantedBy = ["graphical-session.target"];
        partOf = ["graphical-session.target"];
        # A user unit exists for every user; this one runs only for the users
        # `users` names, the ones whose browsers have a port. `|` makes the
        # lines alternatives: any one matching is enough.
        unitConfig.ConditionUser = map (user: "|${user}") (lib.attrNames cfg.users);
        serviceConfig = {
          ExecStart = lib.escapeShellArgs (
            [
              (lib.getExe cfg.package)
              "daemon"
            ]
            ++ lib.optional cfg.dbus "--dbus"
            ++ lib.optionals cfg.mcp.enable (
              [
                "--mcp-policy"
                policyFile
              ]
              ++ lib.optionals (cfg.searchSocket != null) [
                "--search-socket"
                cfg.searchSocket
              ]
              ++ lib.optionals (cfg.blockyUrl != null) [
                "--blocky-url"
                cfg.blockyUrl
              ]
            )
            ++ map (arg: "--browser=${arg}") cfg.browserCommand
            ++ lib.optionals (cfg.launcher != []) (["--launcher"] ++ cfg.launcher)
          );
          Restart = "always";
          RestartSec = 2;
        };
      };
    })
  ];
}
