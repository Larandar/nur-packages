# Ting theme section — popups, menus, panels: dark glass everywhere
# (Glass-Firefox-Theme / TransparentFox heritage). Uses the modern
# --panel-* variables so both menupopups and PanelUI subviews are covered,
# plus the legacy .panel-arrowcontent for extension popups.
ctx: let
  inherit (ctx) css P;
in ''
  /* ============ 8. Popups, menus & panels ============================ */

  menupopup,
  panel {
    --panel-background: rgb(var(--vt-bg-elev-rgb) / var(--vt-popup-alpha, 0.92)) !important;
    --panel-color: var(--vt-text);
    --panel-border-color: rgb(var(--vt-border-rgb) / 0.65) !important;
    --panel-border-radius: var(--vt-radius-lg) !important;
    --panel-shadow: 0 18px 50px rgb(0 0 0 / 0.45) !important;
    --panel-padding: 6px !important;
    --panel-separator-color: rgb(var(--vt-border-rgb) / 0.5) !important;
    color: var(--vt-text);
  }

  /* legacy arrow panels (extension popups, older widgets) */
  .panel-arrowcontent {
    background-color: rgb(var(--vt-bg-elev-rgb) / var(--vt-popup-alpha, 0.92)) !important;
    border-radius: var(--vt-radius-lg) !important;
    border: 1px solid rgb(var(--vt-border-rgb) / 0.65) !important;
    box-shadow: 0 18px 50px rgb(0 0 0 / 0.45) !important;
    color: var(--vt-text);
  }

  menupopup > menu,
  menupopup > menuitem,
  menupopup > menucaption {
    border-radius: var(--vt-radius-sm) !important;
    padding-block: 5px !important;
    margin-inline: 2px !important;
  }

  menupopup > menu:hover:not([disabled="true"]),
  menupopup > menuitem:hover:not([disabled="true"]),
  menupopup > menu[_moz-menuactive="true"],
  menupopup > menuitem[_moz-menuactive="true"] {
    background-color: rgb(var(--vt-accent-rgb) / 0.16) !important;
    color: var(--vt-text) !important;
  }

  menuitem[disabled="true"] {
    color: rgb(var(--vt-text-rgb) / 0.35) !important;
  }

  menuseparator {
    border-color: rgb(var(--vt-border-rgb) / 0.5) !important;
  }

  /* PanelUI internals */
  .panel-header,
  .panel-subview-body,
  .panel-subview-footer {
    background-color: transparent !important;
  }
  .subviewbutton {
    border-radius: var(--vt-radius-sm) !important;
    transition: background-color var(--vt-anim);
  }
  .subviewbutton:hover:not([disabled]) {
    background-color: rgb(var(--vt-accent-rgb) / 0.14) !important;
  }
''
