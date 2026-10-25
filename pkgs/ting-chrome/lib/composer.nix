# Ting — the composer.
#
# Takes a normalized configuration (palette / geometry / minimalism /
# windowControls / ...) and returns the complete theme as strings:
#
#   compose { ... } -> {
#     userChrome    : string   chrome/userChrome.css  (imports palette.css)
#     paletteCss    : string   chrome/palette.css     (the runtime contract)
#     userContent   : string   chrome/userContent.css (inlined colors:
#                              about: pages + DarkReader web theming)
#     sidebery.css  : string   paste into Sidebery Styles editor
#     sidebery.json : string   importable Sidebery settings snapshot
#     meta          : { name, version, dark }
#   }
#
# Design rules baked into this file:
#   * userChrome.css NEVER hardcodes a palette color — it only references
#     --vt-* variables, so palette.css can be swapped at runtime.
#   * Documents that cannot import palette.css (Sidebery's extension
#     document, userContent.css) get the resolved colors inlined.
#   * Build-time decisions (minimalism, geometry) are composed in directly;
#     each of them leaves a runtime about:config escape hatch behind, in the
#     spirit of EdgyArc-fr / FF-ULTIMA.
{lib}: let
  css = import ./css.nix {inherit lib;};
  palettes = import ../modules/palettes.nix;

  inherit
    (css)
    opt
    togglePos
    toggleNeg
    rgba
    rgb
    px
    ;

  # ---- normalizers ------------------------------------------------------
  normalizePalette = p: let
    colors = p.colors or (throw "ting: palette needs a `colors` attrset of 6-hex strings");
    required = [
      "bg"
      "surface"
      "border"
      "text"
      "textDim"
      "accent"
    ];
    missing = builtins.filter (k: !builtins.hasAttr k colors) required;
    _ =
      if missing != []
      then throw "ting: palette missing colors: ${lib.concatStringsSep ", " missing}"
      else null;
  in {
    name = p.name or "custom";
    dark = p.dark or true;
    version = p.version or "0.1.0";
    inherit colors;
    glass =
      {
        panelAlpha = 0.72;
        chromeAlpha = 0.55;
        popupAlpha = 0.92;
      }
      // (p.glass or {});
  };

  normalizeGeometry = g:
    {
      radius = 12; # generic control radius
      radiusSm = 8; # buttons, rows
      radiusLg = 18; # cards, panels, popups
      gap = 6; # outer gutter of floating cards
      navHeight = 44; # nav-bar row height
      tabHeight = 34; # (Sidebery) tab height
      urlbarHeight = 36;
      sidebarWidth = 300;
      blur = 18; # backdrop-filter radius — glass strength
      urlbarFloat = true; # detached pill URL bar (natsumi / safari-ff)
      sidebarFloat = true; # floating glass sidebar card (EdgyArc-like)
      contentFloat = false; # FoxOne-style floating page cards (opt-in)
    }
    // (
      if g == null
      then {}
      else g
    );

  normalizeMinimalism = m:
    {
      hideTabBar = true; # FF-ULTIMA: Sidebery replaces the strip
      hideSidebarHeader = true;
      hideFirefoxSidebarRail = true; # FF 137+ unified-sidebar icon rail
      hideBookmarksBar = false;
      bookmarksAutoHide = true; # reveal on toolbox hover (composer-driven)
      hideNewtabFooter = true; # handled by the module via pref
    }
    // (
      if m == null
      then {}
      else m
    );

  normalizeDarkreader = d:
    {
      enable = true;
      # Web pages keep their own colors unless asked: the CSS engines are
      # heuristics, and half-themed pages read worse than stock ones. The
      # Dark Reader extension, if any, is configured by hand.
      mode = null; # null | tint | invert
      exempt = []; # url-prefixes left untouched
      aboutPages = true; # keep the about:/newtab re-skin
      followScheme = true; # emit prefers-color-scheme light/dark variants
      lightPalette = null; # explicit light palette (used when P is dark)
    }
    // (
      if d == null
      then {}
      else d
    );

  # Luminance-inverted light counterpart of a dark palette — the Dark
  # Reader transform done in nix: swap the paper/ink roles, keep every
  # hue, deepen accents for contrast on a light canvas. Override the
  # whole thing with darkreader.lightPalette when the heuristic offends.
  deriveLight = P: let
    c = P.colors;
  in
    normalizePalette {
      name = "${P.name}-daylight";
      dark = false;
      colors = {
        bg = css.mix c.text "ffffff" 0.55;
        bgElev = css.mix c.text "ffffff" 0.35;
        surface = css.mix c.text "ffffff" 0.22;
        surfaceAlt = css.mix c.text c.bg 0.05;
        border = css.mix c.text c.bg 0.16;
        text = css.mix c.bg c.text 0.88;
        textDim = css.mix c.bg c.text 0.55;
        accent = css.mix c.accent c.bg 0.65;
        accent2 = css.mix c.accent2 c.bg 0.65;
        onAccent = c.onAccent;
        danger = css.mix c.danger c.bg 0.65;
        success = css.mix c.success c.bg 0.65;
        warning = css.mix c.warning c.bg 0.65;
      };
      glass = {
        panelAlpha = 0.85;
        chromeAlpha = 0.75;
        popupAlpha = 0.97;
      };
    };

  # Mirror image for light palettes: derive the nocturne variant.
  deriveDark = P: let
    c = P.colors;
  in
    normalizePalette {
      name = "${P.name}-nocturne";
      dark = true;
      colors = {
        bg = css.mix c.bg "000000" 0.18;
        bgElev = css.mix c.bgElev "000000" 0.16;
        surface = css.mix c.surface "000000" 0.20;
        surfaceAlt = css.mix c.surfaceAlt "000000" 0.22;
        border = css.mix c.border "000000" 0.45;
        text = css.mix "ffffff" c.text 0.85;
        textDim = css.mix "ffffff" c.text 0.55;
        accent = css.mix "ffffff" c.accent 0.12;
        accent2 = css.mix "ffffff" c.accent2 0.12;
        onAccent = c.onAccent;
        danger = css.mix "ffffff" c.danger 0.12;
        success = css.mix "ffffff" c.success 0.12;
        warning = css.mix "ffffff" c.warning 0.12;
      };
      glass = P.glass;
    };

  headerComment = palette: ''
    /* =====================================================================
       Ting — glass chrome for Firefox (Wayland + macOS)
       palette: ${palette.name}   generated: nix (do not edit by hand)
       sources of inspiration: EdgyArc-fr, FF-ULTIMA, TransparentFox, wmfox,
       FoxOne, malevich, natsumi-browser, safari-firefox,
       Glass-Firefox-Theme, Sidebery
       ===================================================================== */
  '';
in {
  inherit normalizePalette normalizeGeometry normalizeMinimalism;
  inherit normalizeDarkreader deriveLight deriveDark;
  inherit css palettes;

  compose = args @ {
    palette ? palettes.ultraviolet,
    geometry ? {},
    minimalism ? {},
    windowControls ? "float", # "float" | "titlebar" | "none"
    userContent ? true,
    sidebery ? true,
    darkreader ? {}, # see normalizeDarkreader
    extraCss ? "",
  }: let
    P = normalizePalette palette;
    G = normalizeGeometry geometry;
    M = normalizeMinimalism minimalism;
    D =
      lib.throwIf ((normalizeDarkreader darkreader).mode == "extension")
      "ting: darkreader.mode \"extension\" is gone; configure the Dark Reader extension by hand, or pick \"tint\" or \"invert\""
      (normalizeDarkreader darkreader);
    WC = windowControls;

    # The active palette always fills its own polarity slot; the opposite
    # slot is derived unless darkreader.lightPalette overrides it.
    V = {
      dark =
        if P.dark
        then P
        else deriveDark P;
      light =
        if P.dark
        then
          (
            if D.lightPalette != null
            then normalizePalette D.lightPalette
            else deriveLight P
          )
        else P;
    };

    # Theme sections read a variant's colors directly (`V.dark.bg`); the
    # composer keeps the whole palettes for itself (`V.dark.colors.bg`).
    ctx = {
      inherit
        css
        palettes
        P
        G
        M
        WC
        D
        ;
      V = {
        dark = V.dark.colors;
        light = V.light.colors;
      };
    };

    sections = map (f: f ctx) (import ../modules/chrome.nix);

    userChrome = lib.concatStringsSep "\n" (
      [
        (headerComment P)
        ''
          @import url("palette.css");
        ''
      ]
      ++ sections
      ++ [(opt (extraCss != "") "\n/* ---- user extras ---- */\n${extraCss}")]
    );

    # --- runtime palette contract: chrome/palette.css -------------------
    c = P.colors;
    paletteCss = css.varsBlock {
      vt-bg = rgb c.bg;
      vt-bg-rgb = css.triplet c.bg;
      vt-bg-elev = rgb c.bgElev;
      vt-bg-elev-rgb = css.triplet c.bgElev;
      vt-surface = rgb c.surface;
      vt-surface-rgb = css.triplet c.surface;
      vt-surface-alt = rgb c.surfaceAlt;
      vt-surface-alt-rgb = css.triplet c.surfaceAlt;
      vt-border = rgb c.border;
      vt-border-rgb = css.triplet c.border;
      vt-text = rgb c.text;
      vt-text-rgb = css.triplet c.text;
      vt-text-dim = rgb c.textDim;
      vt-text-dim-rgb = css.triplet c.textDim;
      vt-accent = rgb c.accent;
      vt-accent-rgb = css.triplet c.accent;
      vt-accent-2 = rgb c.accent2;
      vt-accent-2-rgb = css.triplet c.accent2;
      vt-on-accent = rgb c.onAccent;
      vt-on-accent-rgb = css.triplet c.onAccent;
      vt-danger = rgb c.danger;
      vt-danger-rgb = css.triplet c.danger;
      vt-success = rgb c.success;
      vt-success-rgb = css.triplet c.success;
      vt-warning = rgb c.warning;
      vt-warning-rgb = css.triplet c.warning;
      vt-dark =
        if P.dark
        then "1"
        else "0";
      vt-panel-alpha = toString P.glass.panelAlpha;
      vt-chrome-alpha = toString P.glass.chromeAlpha;
      vt-popup-alpha = toString P.glass.popupAlpha;
    };

    # --- sidebery (needs real colors: extension docs can't @import) ------
    sideberyOut =
      if sidebery
      then import ../modules/chrome/sidebery.nix ctx
      else {
        css = "";
        json = "";
        cssVars = {};
      };

    # --- DarkReader: web content theming (inlined colors, no @import) ----
    drOut =
      if D.enable && D.mode != null
      then (import ../modules/chrome/darkreader.nix) ctx
      else {
        dark = "";
        light = "";
      };

    # about: pages + Firefox Home (inlined colors, no @import)
    aboutOut =
      if userContent && D.aboutPages
      then (import ../modules/chrome/content.nix) ctx
      else {
        dark = "";
        light = "";
      };

    # scheme wrapper for bodies that already carry their own
    # @-moz-document guards (about: pages)
    wrapMedia = body: variant:
      if body == ""
      then ""
      else if D.followScheme
      then "@media (prefers-color-scheme: " + variant + ") {\n" + body + "}\n"
      else body;

    # scheme wrapper for web bodies: document guard OUTSIDE the media
    # query (the shape userContent reliably honors)
    webGuard = "@-moz-document url-prefix(\"http://\"), url-prefix(\"https://\") {";
    webVariant = body: variant:
      if body == ""
      then ""
      else
        webGuard
        + "\n"
        + (
          if D.followScheme
          then "@media (prefers-color-scheme: " + variant + ") {\n" + body + "}\n"
          else body
        )
        + "}\n";

    # exemptions: undo every DarkReader declaration, per site prefix.
    # Plain `unset` rules placed AFTER the variant rules win the !important
    # ties without needing their own scheme wrappers.
    exemptCss = lib.concatStringsSep "\n" (
      map (prefix: ''
        @-moz-document url-prefix("${prefix}") {
          :root { color-scheme: unset; }
          html, body, a, h1, h2, h3, h4, h5, h6, input, textarea, select,
          button, pre, code, kbd, samp, table, th, td, hr, mark {
            background-color: unset !important;
            color: unset !important;
            border-color: unset !important;
            filter: none !important;
            scrollbar-color: auto;
            scrollbar-width: auto;
          }
          ::selection { background-color: unset !important; color: unset !important; }
          img, video, picture, canvas, svg { filter: none !important; }
        }
      '')
      D.exempt
    );

    # printing must stay stock, whatever the screen does
    printGuard = ''
      /* DarkReader: printing stays stock */
      @media print {
        html, body {
          background: #fff !important;
          color: #000 !important;
          filter: none !important;
        }
        img, video, picture, canvas, svg { filter: none !important; }
      }
    '';

    webVariants =
      if D.followScheme
      then [
        (webVariant drOut.dark "dark")
        (webVariant drOut.light "light")
      ]
      else [
        (webVariant (
            if P.dark
            then drOut.dark
            else drOut.light
          ) (
            if P.dark
            then "dark"
            else "light"
          ))
      ];

    webBody = lib.concatStringsSep "\n" (
      lib.filter (s: s != "") (
        webVariants
        ++ [
          exemptCss
          printGuard
        ]
      )
    );

    userContentCss = let
      aboutCss =
        if D.followScheme
        then (wrapMedia aboutOut.dark "dark") + (wrapMedia aboutOut.light "light")
        else
          (
            if P.dark
            then aboutOut.dark
            else aboutOut.light
          );
      # EdgyArc-style runtime escape hatch: about:config boolean pref
      # `ting.darkreader.off` = true switches web theming off.
      drBlock =
        if webBody == ""
        then ""
        else toggleNeg "ting.darkreader.off" webBody;
    in
      lib.concatStringsSep "\n" (
        lib.filter (s: s != "") [
          aboutCss
          drBlock
        ]
      );

    meta = {
      name = P.name;
      version = P.version;
      dark = P.dark;
    };
  in {
    inherit
      userChrome
      paletteCss
      userContentCss
      meta
      ;
    sidebery = sideberyOut;
  };
}
