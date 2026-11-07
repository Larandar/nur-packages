# Ting theme section — userContent.css: about: pages and the Firefox
# Home / new tab, re-skinned with the palette (Glass-Firefox-Theme style).
#
# Returns BOTH scheme variants:
#   { dark = "..."; light = "..."; }
# Each body carries its own @-moz-document guards but NO prefers-color-scheme
# wrapper — the composer wraps them per darkreader.followScheme, so about:
# pages track the same light/dark variant as the DarkReader web theming.
#
# userContent cannot reliably @import palette.css, so the composer inlines
# resolved colors here.
ctx: let
  inherit (ctx) css V P;
  inherit (css) rgb rgba;
in {
  dark = ''
    /* Ting — userContent: about: pages, dark variant (palette: ${P.name}) */

    @-moz-document url-prefix("about:") {
      :root {
        --in-content-page-background: ${rgb V.dark.bg};
        --in-content-page-color: ${rgb V.dark.text};
        --in-content-primary-button-background: ${rgb V.dark.accent};
        --in-content-primary-button-background-hover: ${rgba V.dark.accent 0.85};
        --in-content-primary-button-text-color: ${rgb V.dark.onAccent};
        --in-content-focus-outline-color: ${rgb V.dark.accent};
        --in-content-accent-color: ${rgb V.dark.accent};
        --in-content-button-background: ${rgba V.dark.text 0.08};
        --in-content-button-background-hover: ${rgba V.dark.text 0.14};
        --in-content-box-border-color: ${rgba V.dark.border 0.8};
        --in-content-box-background: ${rgba V.dark.surface 0.9};
      }
    }

    @-moz-document url("about:newtab"), url("about:home") {
      body {
        background-color: ${rgb V.dark.bg} !important;
        background-image:
          radial-gradient(1100px 700px at 75% -10%, ${rgba V.dark.accent 0.16}, transparent 60%),
          radial-gradient(900px 600px at 10% 110%, ${rgba V.dark.accent2 0.10}, transparent 55%) !important;
        color: ${rgb V.dark.text} !important;
      }

      .logo-and-wordmark {
        filter: drop-shadow(0 4px 18px ${rgba V.dark.accent 0.35});
      }

      .search-wrapper .search-handoff-button,
      .search-wrapper input {
        background-color: ${rgba V.dark.surface 0.75} !important;
        border: 1px solid ${rgba V.dark.border 0.8} !important;
        border-radius: 999px !important;
        color: ${rgb V.dark.text} !important;
        box-shadow: 0 6px 22px rgb(0 0 0 / 0.3) !important;
      }
      .search-wrapper input:focus {
        border-color: ${rgba V.dark.accent 0.6} !important;
      }

      .top-site-outer .tile {
        background-color: ${rgba V.dark.text 0.07} !important;
        border-radius: 14px !important;
      }
      .top-site-outer:hover .tile {
        background-color: ${rgba V.dark.accent 0.14} !important;
      }
      .top-site-outer .title {
        color: ${rgba V.dark.text 0.75} !important;
      }

      .ds-card,
      .card-outer,
      .card {
        background-color: ${rgba V.dark.surface 0.7} !important;
        border: 1px solid ${rgba V.dark.border 0.5} !important;
        border-radius: 14px !important;
      }
      .section-title span {
        color: ${rgb V.dark.text} !important;
      }
    }
  '';

  light = ''
    /* Ting — userContent: about: pages, light variant (palette: ${P.name}) */

    @-moz-document url-prefix("about:") {
      :root {
        --in-content-page-background: ${rgb V.light.bg};
        --in-content-page-color: ${rgb V.light.text};
        --in-content-primary-button-background: ${rgb V.light.accent};
        --in-content-primary-button-background-hover: ${rgba V.light.accent 0.85};
        --in-content-primary-button-text-color: ${rgb V.light.onAccent};
        --in-content-focus-outline-color: ${rgb V.light.accent};
        --in-content-accent-color: ${rgb V.light.accent};
        --in-content-button-background: ${rgba V.light.text 0.08};
        --in-content-button-background-hover: ${rgba V.light.text 0.14};
        --in-content-box-border-color: ${rgba V.light.border 0.8};
        --in-content-box-background: ${rgba V.light.surface 0.9};
      }
    }

    @-moz-document url("about:newtab"), url("about:home") {
      body {
        background-color: ${rgb V.light.bg} !important;
        background-image:
          radial-gradient(1100px 700px at 75% -10%, ${rgba V.light.accent 0.14}, transparent 60%),
          radial-gradient(900px 600px at 10% 110%, ${rgba V.light.accent2 0.09}, transparent 55%) !important;
        color: ${rgb V.light.text} !important;
      }

      .logo-and-wordmark {
        filter: drop-shadow(0 4px 18px ${rgba V.light.accent 0.25});
      }

      .search-wrapper .search-handoff-button,
      .search-wrapper input {
        background-color: ${rgba V.light.surface 0.85} !important;
        border: 1px solid ${rgba V.light.border 0.9} !important;
        border-radius: 999px !important;
        color: ${rgb V.light.text} !important;
        box-shadow: 0 4px 16px rgb(0 0 0 / 0.12) !important;
      }
      .search-wrapper input:focus {
        border-color: ${rgba V.light.accent 0.6} !important;
      }

      .top-site-outer .tile {
        background-color: ${rgba V.light.text 0.06} !important;
        border-radius: 14px !important;
      }
      .top-site-outer:hover .tile {
        background-color: ${rgba V.light.accent 0.12} !important;
      }
      .top-site-outer .title {
        color: ${rgba V.light.text 0.75} !important;
      }

      .ds-card,
      .card-outer,
      .card {
        background-color: ${rgba V.light.surface 0.8} !important;
        border: 1px solid ${rgba V.light.border 0.6} !important;
        border-radius: 14px !important;
      }
      .section-title span {
        color: ${rgb V.light.text} !important;
      }
    }
  '';
}
