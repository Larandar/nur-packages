# The themes the waterfox modules offer: `theme` picks one (null keeps Waterfox's own look), `themes.<name>` configures
# it. A theme renders to chrome/ files, the preferences they need, and companions an extension imports by hand.
{lib}: let
  ting = import ../../pkgs/ting-chrome/lib {inherit lib;};
  palettes = ["ultraviolet" "midnight" "porcelain"];

  # `defaults` holds each option's default, and its text where needed: the built-in ones at the top level, the top level's values in a
  # Home Manager profile.
  tingOptions = defaults: {
    paletteSource = lib.mkOption ({
        type = lib.types.enum [
          "stylix"
          "builtin"
        ];
        description = "Where the colors come from: the host's stylix scheme, or `paletteName`.";
      }
      // defaults.paletteSource);
    paletteName = lib.mkOption ({
        type = lib.types.enum palettes;
        description = "The built-in palette when `paletteSource` is `builtin`.";
      }
      // defaults.paletteName);
    palette = lib.mkOption ({
        type = lib.types.nullOr lib.types.anything;
        description = "An inline palette, over `paletteSource`. Shape: see `lib.ting.palettes`.";
      }
      // defaults.palette);
    stylixAccentBase = lib.mkOption ({
        type = lib.types.str;
        description = "The base16 slot used as the accent with a stylix palette.";
      }
      // defaults.stylixAccentBase);
    stylixAccent2Base = lib.mkOption ({
        type = lib.types.str;
        description = "The base16 slot used as the secondary accent with a stylix palette.";
      }
      // defaults.stylixAccent2Base);
    compose = lib.mkOption ({
        type = lib.types.attrsOf lib.types.anything;
        example = {
          geometry.radius = 12;
          minimalism.hideBookmarksBar = true;
          windowControls = "none";
        };
        description = "Further composer arguments: geometry, minimalism, windowControls, userContent, darkreader, extraCss.";
      }
      // defaults.compose);
  };
in {
  # `theme` and `themes`, with the built-in defaults; `hasStylix` picks the palette source.
  options = hasStylix: {
    theme = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum ["ting"]);
      default = null;
      description = "The chrome theme: null keeps Waterfox's own look; \"ting\" is the glass chrome configured by `themes.ting`.";
    };
    themes.ting = tingOptions {
      paletteSource = {
        default =
          if hasStylix
          then "stylix"
          else "builtin";
        defaultText = lib.literalExpression ''if config.lib ? stylix then "stylix" else "builtin"'';
      };
      paletteName.default = "ultraviolet";
      palette.default = null;
      stylixAccentBase.default = "base0C";
      stylixAccent2Base.default = "base0D";
      compose.default = {};
    };
  };

  # The same options defaulting to `top`'s values, and `path` naming them in the documentation.
  inheritedOptions = path: top: {
    theme = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum ["ting"]);
      default = top.theme;
      defaultText = lib.literalExpression "${path}.theme";
      description = "This profile's chrome theme.";
    };
    themes.ting = tingOptions (lib.mapAttrs (name: value: {
        default = value;
        defaultText = lib.literalExpression "${path}.themes.ting.${name}";
      })
      top.themes.ting);
  };

  # A palette source of "stylix" needs stylix: `stylix` is `config.lib.stylix` and `config.stylix` when the host has
  # them, else null.
  assertions = stylix: cfg:
    lib.optional (cfg.theme == "ting") {
      assertion = cfg.themes.ting.palette != null || cfg.themes.ting.paletteSource != "stylix" || stylix != null;
      message = "programs.waterfox.themes.ting.paletteSource = \"stylix\" needs stylix on this host.";
    };

  # `cfg.theme` rendered: `files`, chrome/ file name -> text; `preferences` the chrome needs; `companions`, file name ->
  # text, for extensions to import. Null when no theme is chosen.
  render = {
    stylix,
    isDarwin ? false,
  }: cfg:
    if cfg.theme == null
    then null
    else let
      t = cfg.themes.ting;
      palette =
        if t.palette != null
        then t.palette
        else if t.paletteSource == "stylix"
        then
          ting.fromStylix {
            inherit (stylix) colors polarity;
            accentBase = t.stylixAccentBase;
            accent2Base = t.stylixAccent2Base;
          }
        else ting.palettes.${t.paletteName};
      composed = ting.composer.compose ({inherit palette;} // t.compose);
    in {
      files = ting.chromeFiles composed;
      preferences = ting.prefs {
        windowControls = t.compose.windowControls or "float";
        darkreader = t.compose.darkreader or {};
        minimalism = t.compose.minimalism or {};
        inherit isDarwin;
      };
      companions = lib.filterAttrs (_: text: text != "") {
        "sidebery.css" = composed.sidebery.css;
        "sidebery.json" = composed.sidebery.json;
        "darkreader.json" = composed.darkreaderJson;
      };
    };

  # Rendered `files` as a chrome/ directory.
  chromeDirectory = pkgs: files:
    pkgs.linkFarm "waterfox-chrome" (lib.mapAttrsToList (name: text: {
        inherit name;
        path = pkgs.writeText name text;
      })
      files);

  # `config`'s stylix, as `render` and `assertions` take it.
  stylixOf = config:
    if config.lib ? stylix
    then {
      inherit (config.lib.stylix) colors;
      inherit (config.stylix) polarity;
    }
    else null;
}
