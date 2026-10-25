# Ting theme section — Sidebery v5 companion stylesheet + settings.
#
# Returns:
#   css     — paste into Sidebery ▸ Settings ▸ Styles editor ▸ "Sidebar CSS"
#   json    — importable snapshot { cssVars, sidebarCSS, groupCSS, ver }
#   cssVars — the same variables as an attrset (for inspection)
#
# IMPORTANT: Sidebery lives in a separate extension document — it cannot
# @import chrome/palette.css. The composer therefore inlines resolved
# palette colors here (that is why ctx carries P).
ctx: let
  inherit
    (ctx)
    css
    P
    G
    M
    ;
  inherit (css) rgb rgba;
  c = P.colors;

  vars = {
    frameBg = "transparent";
    tabsHeight = "${css.px G.tabHeight}";
    tabsIndent = "14px";
    navBtnWidth = "40px";
    navBtnHeight = "40px";
  };

  cssVars = {
    # frame + tabs
    bg = "transparent";
    tabs_height = vars.tabsHeight;
    tabs_indent = vars.tabsIndent;
    tabs_fg = rgb c.textDim;
    tabs_fg_hover = rgb c.text;
    tabs_fg_active = rgb c.text;
    tabs_bg = "transparent";
    tabs_bg_hover = rgba c.text 0.07;
    tabs_bg_active = rgba c.accent 0.12;
    tabs_activated_bg = rgba c.accent 0.16;
    tabs_activated_fg = rgb c.text;
    tabs_selected_bg = rgba c.accent 0.16;
    tabs_selected_fg = rgb c.text;
    tabs_border = "transparent";
    tabs_activated_border = "transparent";
    tabs_selected_border = "transparent";
    tabs_shadow = "none";
    tabs_activated_shadow = "none";
    tabs_selected_shadow = "none";
    tabs_lvl_indicator_bg = rgba c.accent 0.5;
    favicons_placeholder_bg = rgba c.surfaceAlt 0.9;
    scroll_progress_bg = rgba c.accent 0.55;
    # nav bar
    nav_btn_fg = rgb c.textDim;
    nav_btn_bg = "transparent";
    nav_btn_bg_hover = rgba c.text 0.07;
    nav_btn_bg_active = rgba c.accent 0.18;
    nav_btn_width = vars.navBtnWidth;
    nav_btn_height = vars.navBtnHeight;
    # buttons
    btn_bg = rgba c.text 0.07;
    btn_bg_hover = rgba c.text 0.12;
    btn_bg_active = rgba c.accent 0.2;
    btn_fg = rgb c.textDim;
    btn_fg_hover = rgb c.text;
    btn_fg_active = rgb c.text;
    # context menu
    ctx_menu_bg = rgba c.bgElev 0.96;
    ctx_menu_bg_hover = rgba c.accent 0.16;
    ctx_menu_fg = rgb c.text;
    # pinned dock
    pinned_dock_overlay_bg = rgba c.bgElev 0.95;
    pinned_dock_overlay_shadow = "0 8px 24px rgb(0 0 0 / 0.35)";
  };

  cssStr = ''
    /* Ting for Sidebery v5 — paste into:
       Sidebery settings > Styles editor > Sidebar CSS
       (colors are inlined: this document cannot import palette.css) */

    #root {
      --frame-bg: ${vars.frameBg};
      --tabs-height: ${vars.tabsHeight};
      --tabs-indent: ${vars.tabsIndent};
      --nav-btn-width: ${vars.navBtnWidth};
      --nav-btn-height: ${vars.navBtnHeight};

      --tabs-fg: ${cssVars.tabs_fg};
      --tabs-fg-hover: ${cssVars.tabs_fg_hover};
      --tabs-fg-active: ${cssVars.tabs_fg_active};
      --tabs-bg: ${cssVars.tabs_bg};
      --tabs-bg-hover: ${cssVars.tabs_bg_hover};
      --tabs-bg-active: ${cssVars.tabs_bg_active};
      --tabs-activated-bg: ${cssVars.tabs_activated_bg};
      --tabs-activated-fg: ${cssVars.tabs_activated_fg};
      --tabs-selected-bg: ${cssVars.tabs_selected_bg};
      --tabs-selected-fg: ${cssVars.tabs_selected_fg};
      --tabs-border: transparent;
      --tabs-activated-border: transparent;
      --tabs-selected-border: transparent;
      --tabs-shadow: none;
      --tabs-activated-shadow: none;
      --tabs-selected-shadow: none;
      --tabs-lvl-indicator-bg: ${cssVars.tabs_lvl_indicator_bg};
      --favicons-placeholder-bg: ${cssVars.favicons_placeholder_bg};
      --scroll-progress-bg: ${cssVars.scroll_progress_bg};

      --nav-btn-fg: ${cssVars.nav_btn_fg};
      --nav-btn-bg: ${cssVars.nav_btn_bg};
      --nav-btn-bg-hover: ${cssVars.nav_btn_bg_hover};
      --nav-btn-bg-active: ${cssVars.nav_btn_bg_active};

      --btn-bg: ${cssVars.btn_bg};
      --btn-bg-hover: ${cssVars.btn_bg_hover};
      --btn-bg-active: ${cssVars.btn_bg_active};
      --btn-fg: ${cssVars.btn_fg};
      --btn-fg-hover: ${cssVars.btn_fg_hover};
      --btn-fg-active: ${cssVars.btn_fg_active};

      --ctx-menu-bg: ${cssVars.ctx_menu_bg};
      --ctx-menu-bg-hover: ${cssVars.ctx_menu_bg_hover};
      --ctx-menu-fg: ${cssVars.ctx_menu_fg};

      --pinned-dock-overlay-bg: ${cssVars.pinned_dock_overlay_bg};
      --pinned-dock-overlay-shadow: ${cssVars.pinned_dock_overlay_shadow};

      color: ${rgb c.text};
      font-size: 13px;
    }

    /* ---------- pill tabs (natsumi curve + EdgyArc active glow) ------- */

    .Tab {
      margin: 2px 6px !important;
      border-radius: 10px !important;
      border: none !important;
      box-shadow: none !important;
      transition: background-color 140ms ease, box-shadow 140ms ease;
    }
    .Tab:hover {
      background-color: ${cssVars.tabs_bg_hover} !important;
    }
    .Tab[data-active="true"] {
      background-color: ${cssVars.tabs_activated_bg} !important;
      box-shadow: inset 0 0 0 1px ${rgba c.accent 0.3} !important;
    }
    .Tab .title { font-size: 12.5px; font-weight: 500; }
    .Tab[data-active="true"] .title { font-weight: 600; }
    .Tab[data-discarded="true"] .title { opacity: 0.55; }
    .Tab .close { border-radius: 6px; }
    .Tab .close:hover {
      background-color: ${rgba c.text 0.14} !important;
    }
    .Tab .audio { color: ${rgb c.accent2}; }

    /* ---------- navigation bar ---------------------------------------- */

    .NavigationBar {
      background-color: transparent !important;
      box-shadow: none !important;
      padding: 4px 6px;
    }
    .NavigationBar .nav-item {
      border-radius: 9px;
      transition: background-color 140ms ease;
    }
    .NavigationBar .nav-item:hover {
      background-color: ${cssVars.nav_btn_bg_hover};
    }
    .NavigationBar .nav-item[data-active="true"] {
      background-color: ${cssVars.nav_btn_bg_active};
    }

    /* ---------- pinned dock & misc ------------------------------------- */

    .PinnedDock { background-color: transparent !important; }
    .Tab[data-pinned="true"] { border-radius: 9px !important; }

    #root * {
      scrollbar-width: thin;
      scrollbar-color: ${rgba c.accent 0.5} transparent;
    }
  '';

  groupCss = ''
    /* Ting group page (Sidebery ▸ Styles editor ▸ Group page CSS) */
    body {
      background-color: ${rgb c.bg};
      color: ${rgb c.text};
    }
  '';

  json = builtins.toJSON {
    cssVars = cssVars;
    sidebarCSS = cssStr;
    groupCSS = groupCss;
    ver = "5";
  };
in {
  css = cssStr;
  inherit json cssVars;
}
