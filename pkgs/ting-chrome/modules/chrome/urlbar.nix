# Ting theme section — the floating URL bar (natsumi-browser /
# safari-firefox style): a detached pill in the nav row with glass results
# that genuinely blur the page behind them when focused.
#
# composer decisions:
#   G.urlbarFloat = true  -> float styles, escape hatch ting.urlbar.dock
#   G.urlbarFloat = false -> docked (firefox default), no styles emitted
ctx: let
  inherit (ctx) css G;
  body = ''
    /* ============ 6. Floating URL bar ================================= */

    #urlbar-container {
      padding-block: 0 !important;
    }

    #urlbar-background {
      border-radius: 999px !important;
      background-color: rgb(var(--vt-surface-alt-rgb) / 0.55) !important;
      border: 1px solid rgb(var(--vt-border-rgb) / 0.65) !important;
      box-shadow: 0 1px 10px rgb(0 0 0 / 0.22),
                  inset 0 1px 0 rgb(var(--vt-text-rgb) / 0.04) !important;
      transition: background-color var(--vt-anim),
                  border-color var(--vt-anim),
                  box-shadow var(--vt-anim);
    }

    #urlbar:hover #urlbar-background {
      background-color: rgb(var(--vt-surface-alt-rgb) / 0.68) !important;
    }

    #urlbar[focused="true"] #urlbar-background,
    #urlbar[open="true"] #urlbar-background {
      background-color: rgb(var(--vt-surface-alt-rgb) / 0.88) !important;
      border-color: rgb(var(--vt-accent-rgb) / 0.55) !important;
      box-shadow: 0 0 0 3px rgb(var(--vt-accent-rgb) / 0.16),
                  0 8px 26px rgb(0 0 0 / 0.30) !important;
    }

    .urlbar-input-container {
      background-color: transparent !important;
      border: none !important;
      border-radius: inherit;
      padding-inline: 8px !important;
    }

    #urlbar-input::placeholder {
      color: rgb(var(--vt-text-rgb) / 0.38);
    }

    /* results panel — overlaps the page, so backdrop-filter really blurs */
    .urlbarView {
      background-color: rgb(var(--vt-bg-elev-rgb) / var(--vt-popup-alpha, 0.92)) !important;
      backdrop-filter: blur(var(--vt-blur)) saturate(1.35);
      border-radius: var(--vt-radius-lg) !important;
      border: 1px solid rgb(var(--vt-border-rgb) / 0.60) !important;
      box-shadow: 0 18px 50px rgb(0 0 0 / 0.40) !important;
      padding-block: 4px !important;
    }

    .urlbarView-row {
      border-radius: var(--vt-radius-sm) !important;
      margin-inline: 6px !important;
      padding-inline: 8px !important;
    }
    .urlbarView-row[row-select="true"],
    .urlbarView-row:hover {
      background-color: rgb(var(--vt-accent-rgb) / 0.15) !important;
    }
    .urlbarView-title { color: var(--vt-text); }
    .urlbarView-url,
    .urlbarView-action { color: rgb(var(--vt-accent-rgb) / 0.9); }

    .search-one-offs {
      background-color: transparent !important;
      border-top: 1px solid rgb(var(--vt-border-rgb) / 0.45) !important;
    }
    .searchbar-engine-one-off-item {
      border-radius: var(--vt-radius-sm) !important;
    }
  '';
  # The nav row splits at the sidebar's edge while the sidebar is open: every
  # button above the sidebar, the URL bar over the page, from its left edge to
  # the window controls. The sidebar takes --vt-sidebar-w so both halves
  # agree; a profile resizes it by redefining that variable, not by dragging.
  # 30px is what Gecko 153 leaves outside the two halves (the window edges,
  # the gaps around the sidebar card, the button row's trailing inset);
  # 118px is the window controls' room (./tabbar.nix).
  split = ''
    /* ============ 6b. Nav row split at the sidebar ==================== */

    :root:has(#sidebar-box:not([hidden])) #sidebar-box {
      width: var(--vt-sidebar-w) !important;
      min-width: var(--vt-sidebar-w) !important;
      max-width: var(--vt-sidebar-w) !important;
    }
    :root:has(#sidebar-box:not([hidden])) #PanelUI-button {
      order: -1;
    }
    :root:has(#sidebar-box:not([hidden])) #urlbar-container {
      order: 1;
      margin-inline-start: auto !important;
      flex: 0 0 auto !important;
      width: calc(100vw - var(--vt-sidebar-w) - 118px - 30px) !important;
      max-width: none !important;
    }
  '';
in
  (
    if G.urlbarFloat
    then css.toggleNeg "ting.urlbar.dock" body
    else ""
  )
  + css.toggleNeg "ting.urlbar.inline" split
