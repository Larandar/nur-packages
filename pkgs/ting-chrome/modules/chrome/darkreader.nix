# Ting theme section — DarkReader: palette-driven web content theming.
#
# Engines (darkreader.mode):
#   tint      targeted element overrides — an honest heuristic: html/body,
#             links, headings, forms, code, tables, selection, scrollbars.
#             Keeps layout and position:fixed intact; some sites leak.
#   invert    html filter invert(1) + hue-rotate with media re-inversion —
#             converts everything, breaks position:fixed on some pages.
#             The canvas is pre-painted with invertHex(target) so the filter
#             lands exactly on the palette background.
#
# Returns { dark, light } rule bodies WITHOUT document guards or
# prefers-color-scheme wrappers — the composer wraps them (@-moz-document
# outer, @media inner) per darkreader.followScheme, then adds the
# ting.darkreader.off escape hatch.
ctx: let
  inherit
    (ctx)
    css
    V
    P
    D
    ;
  inherit (css) rgb rgba invertHex;
in
  if D.mode == "invert"
  then {
    dark = ''
      /* Ting DarkReader — invert engine, dark variant (palette: ${P.name}) */

      :root { color-scheme: dark; }

      html {
        background-color: ${invertHex V.dark.bg} !important;
        filter: invert(1) hue-rotate(180deg) !important;
      }

      /* media must survive the inversion */
      img, video, picture, canvas, svg, iframe, embed, object,
      [style*="background-image: url"], [style*="background-image:url"],
      [style*="background: url"], [style*="background:url"] {
        filter: invert(1) hue-rotate(180deg) !important;
      }

      /* known caveat: position:fixed elements anchor to the filtered root */
    '';
    light = "";
  }
  else {
    dark = ''
      /* Ting DarkReader — tint engine, dark variant (palette: ${P.name}) */

      :root {
        color-scheme: dark;
        --vdr-bg: ${rgb V.dark.bg};
        --vdr-bg-elev: ${rgb V.dark.bgElev};
        --vdr-fg: ${rgb V.dark.text};
        --vdr-fg-dim: ${rgb V.dark.textDim};
        --vdr-accent: ${rgb V.dark.accent};
        --vdr-border: ${rgb V.dark.border};
      }

      html {
        background-color: var(--vdr-bg) !important;
        scrollbar-color: var(--vdr-accent) transparent;
      }
      body {
        background-color: var(--vdr-bg) !important;
        color: var(--vdr-fg) !important;
      }

      a { color: var(--vdr-accent) !important; }
      a:visited { color: ${rgb V.dark.accent2} !important; }
      h1, h2, h3, h4, h5, h6 { color: var(--vdr-fg) !important; }

      input, textarea, select {
        background-color: ${rgba V.dark.surface 0.9} !important;
        color: var(--vdr-fg) !important;
        border-color: ${rgba V.dark.border 0.8} !important;
      }
      button {
        background-color: ${rgba V.dark.surfaceAlt 0.85} !important;
        color: var(--vdr-fg) !important;
        border-color: ${rgba V.dark.border 0.6} !important;
      }

      pre, code, kbd, samp {
        background-color: var(--vdr-bg-elev) !important;
        color: var(--vdr-fg) !important;
      }
      table, th, td, hr { border-color: ${rgba V.dark.border 0.7} !important; }
      mark {
        background-color: ${rgba V.dark.warning 0.35} !important;
        color: var(--vdr-fg) !important;
      }

      ::selection {
        background-color: ${rgba V.dark.accent 0.85} !important;
        color: ${rgb V.dark.onAccent} !important;
      }

      /* take the edge off blinding media, keep it recognizable */
      img, video, picture, canvas, svg { filter: brightness(0.92) contrast(1.04); }
    '';

    light = ''
      /* Ting DarkReader — tint engine, light variant (palette: ${P.name}) */

      :root {
        color-scheme: light;
        --vdr-bg: ${rgb V.light.bg};
        --vdr-bg-elev: ${rgb V.light.bgElev};
        --vdr-fg: ${rgb V.light.text};
        --vdr-fg-dim: ${rgb V.light.textDim};
        --vdr-accent: ${rgb V.light.accent};
        --vdr-border: ${rgb V.light.border};
      }

      html {
        background-color: var(--vdr-bg) !important;
        scrollbar-color: var(--vdr-accent) transparent;
      }
      body {
        background-color: var(--vdr-bg) !important;
        color: var(--vdr-fg) !important;
      }

      a { color: var(--vdr-accent) !important; }
      a:visited { color: ${rgb V.light.accent2} !important; }
      h1, h2, h3, h4, h5, h6 { color: var(--vdr-fg) !important; }

      input, textarea, select {
        background-color: ${rgba V.light.surface 0.95} !important;
        color: var(--vdr-fg) !important;
        border-color: ${rgba V.light.border 0.9} !important;
      }
      button {
        background-color: ${rgba V.light.surfaceAlt 0.9} !important;
        color: var(--vdr-fg) !important;
        border-color: ${rgba V.light.border 0.7} !important;
      }

      pre, code, kbd, samp {
        background-color: var(--vdr-bg-elev) !important;
        color: var(--vdr-fg) !important;
      }
      table, th, td, hr { border-color: ${rgba V.light.border 0.8} !important; }
      mark {
        background-color: ${rgba V.light.warning 0.4} !important;
        color: var(--vdr-fg) !important;
      }

      ::selection {
        background-color: ${rgba V.light.accent 0.7} !important;
        color: ${rgb V.light.onAccent} !important;
      }
    '';
  }
