# What the NixOS and Home Manager waterfox modules share: the wrapper's arguments (pkgs/waterfox) as options, and the
# package they make by laying them over a base Waterfox.
{lib}: let
  scalar = with lib.types;
    oneOf [
      bool
      int
      str
    ];
  preference = lib.types.either scalar (lib.types.submodule {
    options = {
      value = lib.mkOption {type = scalar;};
      status = lib.mkOption {
        type = lib.types.enum [
          "locked"
          "default"
          "user"
        ];
        default = "locked";
      };
    };
  });
in {
  options = pkgs: {
    enable = lib.mkEnableOption "Waterfox";
    basePackage = lib.mkOption {
      type = lib.types.package;
      default = (import ../.. {inherit pkgs;}).waterfox;
      defaultText = lib.literalExpression "nur-packages.waterfox";
      description = "The Waterfox these options are laid over, with `.override`.";
    };
    policies = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      description = "Enterprise policies, written as distribution/policies.json; updates are always off.";
    };
    preferences = lib.mkOption {
      type = lib.types.attrsOf preference;
      default = {};
      example = {
        "browser.startup.page" = 3;
        "general.smoothScroll" = {
          value = false;
          status = "default";
        };
      };
      description = "Preferences, written as AutoConfig. A bare value is locked; `{ value; status; }` picks `locked`, `default` (the user may change it) or `user` (re-asserted every launch).";
    };
    extensions = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          id = lib.mkOption {type = lib.types.str;};
          xpi = lib.mkOption {type = lib.types.path;};
        };
      });
      default = [];
      description = "Extensions force-installed from local XPIs.";
    };
    certificates = lib.mkOption {
      type = lib.types.listOf (lib.types.either lib.types.path lib.types.str);
      default = [];
      description = "Root certificates every profile trusts, as PEM files or PEM text, through the `Certificates` policy: Waterfox reads its own NSS store, not the system bundle.";
    };
    chrome = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "A directory holding userChrome.css and userContent.css, registered by AutoConfig for every profile.";
    };
    searchEngine = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          name = lib.mkOption {type = lib.types.str;};
          url = lib.mkOption {
            type = lib.types.str;
            description = "Query URL with `{searchTerms}`.";
          };
        };
      });
      default = null;
      description = "A search engine added and locked as the default.";
    };
    desktopEntry = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = {};
      example = {desktopName = "Waterfox (work)";};
      description = "makeDesktopItem fields laid over the default desktop entry.";
    };
    icon = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "An image for the desktop entry; null keeps Waterfox's own.";
    };
    wmClass = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "The window class (`--name`) the desktop entry runs with; null keeps Waterfox's.";
    };
    newTabCommand = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = ["/run/current-system/sw/bin/fuzzel"];
      description = "An argv, absolute program first, that Ctrl+T runs instead of opening a tab.";
    };
    loginStorage = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum ["multipass"]);
      default = null;
      description = "Where the login manager keeps logins: null for the profile's logins.json, \"multipass\" for the user's multipass service (ad.lar.MultiPass).";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "The Waterfox these options make: `basePackage` overridden with them.";
    };
  };

  package = pkgs: cfg:
    cfg.basePackage.override {
      inherit (cfg) preferences extensions chrome searchEngine desktopEntry icon wmClass newTabCommand loginStorage;
      policies =
        lib.recursiveUpdate cfg.policies
        (lib.optionalAttrs (cfg.certificates != []) {
          Certificates.Install =
            lib.imap0 (
              i: certificate:
                if builtins.isPath certificate || lib.hasPrefix "/" certificate
                then "${certificate}"
                else "${pkgs.writeText "waterfox-root-${toString i}.pem" certificate}"
            )
            cfg.certificates;
        });
    };
}
