# Ting — built-in palettes + bridges to external palette sources.
#
# A palette is a plain attrset:
# {
#   name   = "ultraviolet";
#   dark   = true;      # used by consumers / docs; CSS never switches on it
#   colors = { bg bgElev surface surfaceAlt border text textDim
#              accent accent2 onAccent danger success warning };  # 6-hex
#   glass  = { panelAlpha chromeAlpha popupAlpha };  # opacity of glass layers
# }
#
# The palette file emitted for Firefox (chrome/palette.css) exposes every
# color as --vt-<name> AND --vt-<name>-rgb triplets, plus the glass alphas.
# That file is the *runtime* contract: stylix, matugen, pywalfox or the
# bundled time-of-day daemon can rewrite it without touching the chrome.
let
  # luminance of a 6-hex color, 0..1 — used to sanity-check contrast of
  # generated accents and by fromBase16 to guess light/dark.
  lum = css: c: let
    rgb = css.hexToRgb c;
    f = v: v / 255.0;
  in
    0.2126
    * (f (builtins.elemAt rgb 0))
    + 0.7152 * (f (builtins.elemAt rgb 1))
    + 0.0722 * (f (builtins.elemAt rgb 2));

  mk = name: dark: colors: glass: {
    inherit
      name
      dark
      colors
      glass
      ;
  };

  ultraviolet =
    mk "ultraviolet" true
    {
      bg = "12121c";
      bgElev = "1a1a2b";
      surface = "1e1e30";
      surfaceAlt = "262640";
      border = "353552";
      text = "eaeaf6";
      textDim = "9d9dc0";
      accent = "a78bfa";
      accent2 = "67e8f9";
      onAccent = "14142a";
      danger = "f87171";
      success = "34d399";
      warning = "fbbf24";
    }
    {
      panelAlpha = 0.72;
      chromeAlpha = 0.55;
      popupAlpha = 0.92;
    };

  midnight =
    mk "midnight" true
    {
      bg = "0d1420";
      bgElev = "101a2b";
      surface = "14213a";
      surfaceAlt = "1b2c4a";
      border = "243a5c";
      text = "e2eaf5";
      textDim = "8fa3bf";
      accent = "22d3ee";
      accent2 = "a5b4fc";
      onAccent = "06131a";
      danger = "fb7185";
      success = "4ade80";
      warning = "facc15";
    }
    {
      panelAlpha = 0.66;
      chromeAlpha = 0.50;
      popupAlpha = 0.90;
    };

  porcelain =
    mk "porcelain" false
    {
      bg = "f2efe7";
      bgElev = "f7f5ef";
      surface = "fbf9f4";
      surfaceAlt = "ece5d8";
      border = "d9cfbd";
      text = "2a2620";
      textDim = "7a7264";
      accent = "c2542e";
      accent2 = "3e7d6a";
      onAccent = "fdf8f3";
      danger = "b3413b";
      success = "2f7d5b";
      warning = "a8762a";
    }
    {
      panelAlpha = 0.85;
      chromeAlpha = 0.75;
      popupAlpha = 0.97;
    };
in {
  inherit ultraviolet midnight porcelain;
  default = ultraviolet;
  all = [
    ultraviolet
    midnight
    porcelain
  ];

  # Bridge any base16 scheme (stylix exposes `config.stylix.colors` as
  # base00..base0F strings) into a Ting palette.
  #
  #   programs.ting.paletteSource = "stylix";
  #
  # picks accent/accent2 via `accentBase`/`accent2Base` (default base0C /
  # base0D — the usual cyan/blue slots; base08 red..base0E magenta also work).
  fromBase16 = {
    accentBase ? "base0C",
    accent2Base ? "base0D",
    dark ? true,
  }: b16:
    mk "stylix-${b16.schemeName or "base16"}" dark
    {
      bg = b16.base00;
      bgElev = b16.base01;
      surface = b16.base01;
      surfaceAlt = b16.base02;
      border = b16.base03;
      textDim = b16.base04;
      text = b16.base05;
      onAccent = b16.base00;
      accent = b16.${accentBase};
      accent2 = b16.${accent2Base};
      danger = b16.base08;
      success = b16.base0B;
      warning = b16.base0A;
    }
    (
      if dark
      then {
        panelAlpha = 0.72;
        chromeAlpha = 0.55;
        popupAlpha = 0.92;
      }
      else {
        panelAlpha = 0.85;
        chromeAlpha = 0.75;
        popupAlpha = 0.97;
      }
    );

  inherit lum;
}
