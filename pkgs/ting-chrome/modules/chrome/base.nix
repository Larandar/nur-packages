# Ting theme section — base: tokens, glass toolbox, nav bar, buttons.
ctx: let
  inherit
    (ctx)
    css
    P
    G
    M
    WC
    ;
  inherit (css) px;
in ''
  /* ============================ 1. Tokens ============================ */

  :root {
    /* geometry — baked at build time by the composer */
    --vt-radius: ${px G.radius};
    --vt-radius-sm: ${px G.radiusSm};
    --vt-radius-lg: ${px G.radiusLg};
    --vt-gap: ${px G.gap};
    --vt-nav-h: ${px G.navHeight};
    --vt-tab-h: ${px G.tabHeight};
    --vt-urlbar-h: ${px G.urlbarHeight};
    --vt-sidebar-w: ${px G.sidebarWidth};
    --vt-blur: ${px G.blur};
    --vt-anim: 160ms cubic-bezier(.22, .8, .26, 1);

    /* firefox integration overrides */
    --toolbar-bgcolor: transparent;
    --toolbar-non-lwt-bgcolor: transparent;
    --toolbarbutton-border-radius: var(--vt-radius-sm);
    --arrowpanel-border-radius: var(--vt-radius-lg);
    --tab-border-radius: var(--vt-radius-sm);
    --tab-min-height: var(--vt-tab-h);
    --urlbar-height: var(--vt-urlbar-h);
    --urlbar-toolbar-height: var(--vt-nav-h);
    --urlbar-container-height: var(--vt-nav-h);
    --chrome-content-separator-color: transparent;
    --lwt-header-image: none;
    --arrowpanel-dimmed: rgb(var(--vt-text-rgb) / 0.07);
    --arrowpanel-dimmed-further: rgb(var(--vt-text-rgb) / 0.12);
    --button-bgcolor: rgb(var(--vt-text-rgb) / 0.07);
    --button-hover-bgcolor: rgb(var(--vt-text-rgb) / 0.13);
    --focus-outline-color: rgb(var(--vt-accent-rgb) / 0.65);
    --sidebar-background-color: transparent;
    --sidebar-border-color: transparent;
    --urlbarView-highlight-background: rgb(var(--vt-accent-rgb) / 0.16);
    --urlbarView-highlight-color: var(--vt-text);
  }

  /* the window: the dark base every glass layer floats on */
  #main-window,
  #browser-panel,
  #browser {
    background-color: var(--vt-bg) !important;
  }

  /* ====================== 2. The glass toolbox ====================== */
  /* One translucent slab behind every toolbar row. On macOS the
     behind-window titlebar blend bleeds the desktop through it; on Wayland
     your compositor (KWin / Hyprland) blurs what sits behind the window.  */

  #navigator-toolbox {
    position: relative;
    background-color: rgb(var(--vt-surface-rgb) / var(--vt-chrome-alpha, 0.55)) !important;
    backdrop-filter: blur(var(--vt-blur)) saturate(1.35);
    border-bottom: 1px solid rgb(var(--vt-accent-rgb) / 0.10) !important;
    box-shadow: none !important;
  }

  /* private windows get a violet breath */
  :root[privatebrowsingmode="temporary"] #navigator-toolbox {
    background-image: linear-gradient(rgb(var(--vt-accent-rgb) / 0.10),
                                       rgb(var(--vt-accent-rgb) / 0.10)) !important;
  }

  /* nav bar: transparent layer inside the toolbox; drag region */
  #nav-bar {
    background-color: transparent !important;
    background-image: none !important;
    border: none !important;
    box-shadow: none !important;
    padding-block: 5px !important;
    -moz-window-dragging: drag;
  }
  #nav-bar .titlebar-spacer[type="pre-tabs"],
  #nav-bar .titlebar-spacer[type="post-tabs"] {
    display: none !important;
  }

  /* ====================== 3. Buttons as pills ======================= */

  .toolbarbutton-1,
  .toolbarbutton-1 > .toolbarbutton-menubutton-button {
    border-radius: var(--vt-radius-sm) !important;
    transition: background-color var(--vt-anim), box-shadow var(--vt-anim);
  }
  .toolbarbutton-1:hover:not([disabled]),
  .toolbarbutton-1[open="true"],
  .toolbarbutton-1 > .toolbarbutton-menubutton-button:hover {
    background-color: rgb(var(--vt-accent-rgb) / 0.14) !important;
    box-shadow: inset 0 0 0 1px rgb(var(--vt-accent-rgb) / 0.22);
  }
  .toolbarbutton-1[disabled] {
    opacity: 0.4;
  }

  toolbarseparator {
    border-color: rgb(var(--vt-border-rgb) / 0.6) !important;
  }
''
