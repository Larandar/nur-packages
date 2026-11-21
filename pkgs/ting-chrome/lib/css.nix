# Ting — tiny CSS composition helpers (pure nix).
#
# Every color in a Ting palette is a 6-digit hex string, with or without
# the leading "#". At composition time colors are expanded into:
#   * space-separated rgb triplets  ->  emitted as --vt-accent-rgb so runtime
#     alpha derivation works: rgb(var(--vt-accent-rgb) / 0.16)
#   * resolved rgb()/rgba() strings for documents that cannot import
#     palette.css (Sidebery's extension document, userContent.css).
#
# Keeping the triplet as the runtime unit means swapping palette.css at
# runtime re-tints every derived alpha automatically — the chrome CSS never
# hardcodes a color.
{lib}: let
  hexDigits = {
    "0" = 0;
    "1" = 1;
    "2" = 2;
    "3" = 3;
    "4" = 4;
    "5" = 5;
    "6" = 6;
    "7" = 7;
    "8" = 8;
    "9" = 9;
    "a" = 10;
    "b" = 11;
    "c" = 12;
    "d" = 13;
    "e" = 14;
    "f" = 15;
  };

  toLower = builtins.replaceStrings ["A" "B" "C" "D" "E" "F"] ["a" "b" "c" "d" "e" "f"];

  hexVal = c:
    if builtins.hasAttr c hexDigits
    then hexDigits.${c}
    else throw "ting: '${c}' is not a hex digit (colors must be 6-digit hex)";

  hexToRgb = color: let
    h = builtins.replaceStrings ["#"] [""] (toLower color);
    len = builtins.stringLength h;
    _ =
      if len != 6
      then throw "ting: color '${color}' must be 6 hex digits"
      else null;
    charAt = i: builtins.substring i 1 h;
  in
    map (i: (hexVal (charAt i)) * 16 + (hexVal (charAt (i + 1)))) [
      0
      2
      4
    ];

  # Format an alpha value for CSS. Accepts floats/ints; toString already
  # yields CSS-friendly output ("1", "0.72", "0.16").
  alphaStr = a: toString a;

  hexChars = [
    "0"
    "1"
    "2"
    "3"
    "4"
    "5"
    "6"
    "7"
    "8"
    "9"
    "a"
    "b"
    "c"
    "d"
    "e"
    "f"
  ];

  # mix "#a78bfa" "#12121c" 0.3 -> "#5b5f92"
  # Channel-wise lerp; t is the weight of the FIRST color. Used by the
  # composer to derive light/dark palette variants (the DarkReader
  # transform: keep the hue, invert the luminance role).
  mix = a: b: t: let
    ra = hexToRgb a;
    rb = hexToRgb b;
    chan = i: let
      v = (builtins.elemAt ra i) * t + (builtins.elemAt rb i) * (1.0 - t);
      q = builtins.floor (v / 16.0);
      r = (builtins.floor v) - q * 16;
    in
      builtins.elemAt hexChars q + builtins.elemAt hexChars r;
  in
    "#" + chan 0 + chan 1 + chan 2;

  # "#12121c" -> "#edede3"-style per-channel photographic inverse
  # (255 - v). The DarkReader invert engine paints the canvas with
  # invertHex(target) so that filter: invert(1) lands exactly on target.
  invertHex = color: let
    v = hexToRgb color;
    chan = i: let
      n = 255 - builtins.elemAt v i;
    in
      builtins.elemAt hexChars (n / 16) + builtins.elemAt hexChars (n - (n / 16) * 16);
  in
    "#" + chan 0 + chan 1 + chan 2;

  # "#a78bfa" -> "167 139 250" (bound here: rgb and rgba below use it,
  # and the attribute set they live in is not recursive)
  triplet = color: builtins.concatStringsSep " " (map toString (hexToRgb color));
in {
  inherit
    hexToRgb
    alphaStr
    mix
    invertHex
    triplet
    ;

  # "#a78bfa" -> "rgb(167 139 250)"
  rgb = color: "rgb(${triplet color})";

  # "#a78bfa" 0.16 -> "rgb(167 139 250 / 0.16)"
  rgba = color: alpha: "rgb(${triplet color} / ${alphaStr alpha})";

  # 12 -> "12px"
  px = n: "${toString n}px";

  # conditional snippet
  opt = cond: body:
    if cond
    then body
    else "";

  # :root { --x: y; } block
  varsBlock = attrs:
    ":root {\n"
    + builtins.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "  --${k}: ${v};") attrs)
    + "\n}\n";

  # Wrap a block in an about:config runtime toggle (EdgyArc / FF-ULTIMA
  # style). positive: active while pref is true; negative: active while the
  # pref is absent/false — the usual "escape hatch" pattern. Gecko reads a
  # pref query only as `@media -moz-pref()`; under `@supports
  # -moz-bool-pref()` every gated block is dropped.
  togglePos = pref: body: "@media -moz-pref(\"${pref}\") {\n${body}}\n";
  toggleNeg = pref: body: "@media not -moz-pref(\"${pref}\") {\n${body}}\n";
}
