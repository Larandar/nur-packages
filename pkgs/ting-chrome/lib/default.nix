# Ting library entrypoint — exposes css helpers, palettes and composer, and
# what every consumer of a composed theme needs: the stylix bridge, the
# preferences the chrome depends on, and the chrome/ files themselves.
{lib}: let
  palettes = import ../modules/palettes.nix;
in {
  css = import ./css.nix {inherit lib;};
  inherit palettes;
  composer = import ./composer.nix {inherit lib;};

  # A stylix scheme (`lib.stylix.colors`, base00..base0F) as a Ting palette;
  # `polarity` is stylix's own, and picks the glass alphas.
  fromStylix = {
    colors,
    polarity ? "dark",
    accentBase ? "base0C",
    accent2Base ? "base0D",
  }:
    palettes.fromBase16 {
      inherit accentBase accent2Base;
      dark = polarity != "light";
    }
    colors;

  # The preferences userChrome.css and the glass features need, for the
  # composer arguments the theme was built with.
  prefs = {
    windowControls ? "float",
    darkreader ? {},
    minimalism ? {},
    isDarwin ? false,
  }:
    {
      "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
      "svg.context-properties.content.enabled" = true;
      "layout.css.color-mix.enabled" = true;
      "layout.css.light-dark.enabled" = true;
      "layout.css.has-selector.enabled" = true;
      "widget.macos.titlebar-blend-mode.behind-window" = isDarwin;
    }
    // lib.optionalAttrs (windowControls == "titlebar") {
      "browser.tabs.inTitlebar" = 0;
    }
    // lib.optionalAttrs ((darkreader.enable or true) && (darkreader.followScheme or true)) {
      "layout.css.prefers-color-scheme.content-override" = 2;
    }
    // lib.optionalAttrs (minimalism.hideNewtabFooter or true) {
      "browser.newtabpage.activity-stream.feeds.snippets" = false;
    };

  # A composed theme's chrome/ directory, as file name -> content.
  chromeFiles = composed:
    {
      "userChrome.css" = composed.userChrome;
      "palette.css" = composed.paletteCss;
    }
    // lib.optionalAttrs (composed.userContentCss != "") {
      "userContent.css" = composed.userContentCss;
    };
}
