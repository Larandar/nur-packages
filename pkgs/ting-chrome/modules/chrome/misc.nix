# Ting theme section — everything else, composed:
#   findbar card, status pill, slim scrollbars, bookmarks-bar behaviour,
#   optional floating content cards (FoxOne), opaque escape hatch,
#   fullscreen guards.
#
# composer decisions:
#   M.hideBookmarksBar   -> bookmarks bar removed
#   M.bookmarksAutoHide  -> bar revealed while the toolbox is hovered
#   G.contentFloat = true  -> floating page cards, escape hatch ting.content.dock
#   G.contentFloat = false -> docked by default, enabled by ting.content.float
ctx: let
  inherit (ctx) css G M;

  findbar = ''
    /* ============ 9. Findbar — floating glass card ==================== */

    findbar {
      background-color: rgb(var(--vt-surface-rgb) / 0.90) !important;
      backdrop-filter: blur(12px) saturate(1.25);
      border: none !important;
      border-bottom: 1px solid rgb(var(--vt-accent-rgb) / 0.25) !important;
      margin: 0 var(--vt-gap) !important;
      border-radius: 0 0 var(--vt-radius) var(--vt-radius);
      box-shadow: 0 10px 26px rgb(0 0 0 / 0.28);
    }
    findbar .findbar-textbox {
      background-color: rgb(var(--vt-text-rgb) / 0.08) !important;
      border: 1px solid rgb(var(--vt-border-rgb) / 0.6) !important;
      border-radius: 999px !important;
      color: var(--vt-text) !important;
    }
    findbar .findbar-textbox:focus {
      border-color: rgb(var(--vt-accent-rgb) / 0.6) !important;
      outline: none !important;
    }
  '';

  statusPill = ''
    /* ============ 10. Status pill (hovered links) ===================== */

    #statuspanel { padding: 3px 6px; }
    #statuspanel-label {
      background-color: rgb(var(--vt-bg-elev-rgb) / 0.92) !important;
      color: rgb(var(--vt-text-rgb) / 0.8) !important;
      border: 1px solid rgb(var(--vt-border-rgb) / 0.55) !important;
      border-radius: 8px !important;
      padding: 2px 10px !important;
    }
  '';

  scrollbars = ''
    /* ============ 11. Slim accent scrollbars ========================== */

    * {
      scrollbar-color: rgb(var(--vt-accent-rgb) / 0.45) transparent;
      scrollbar-width: thin;
    }
  '';

  bookmarksBar = (
    if M.hideBookmarksBar
    then ''
      /* ============ 12. Bookmarks bar removed ========================= */

      #PersonalToolbar { display: none !important; }
    ''
    else
      (
        if M.bookmarksAutoHide
        then ''
          /* ============ 12. Bookmarks bar — auto-reveal on toolbox hover == */

          #PersonalToolbar {
            background-color: transparent !important;
            padding-inline: 8px !important;
            transition: opacity var(--vt-anim), transform 200ms ease;
            opacity: 0;
            transform: translateY(-6px);
          }
          #navigator-toolbox:has(:hover) #PersonalToolbar,
          #navigator-toolbox:has(:focus-within) #PersonalToolbar,
          #navigator-toolbox[customizing] #PersonalToolbar {
            opacity: 1;
            transform: none;
          }
          .bookmark-item {
            border-radius: var(--vt-radius-sm);
          }
          .bookmark-item:hover {
            background-color: rgb(var(--vt-accent-rgb) / 0.14) !important;
          }
        ''
        else ''
          /* ============ 12. Bookmarks bar — glass, always visible ========= */

          #PersonalToolbar {
            background-color: transparent !important;
            padding-inline: 8px !important;
          }
          .bookmark-item { border-radius: var(--vt-radius-sm); }
          .bookmark-item:hover {
            background-color: rgb(var(--vt-accent-rgb) / 0.14) !important;
          }
        ''
      )
  );

  contentFloatBody = ''
    /* ============ 13. Floating content cards (FoxOne-style) =========== */

    #tabbrowser-tabpanels {
      background-color: transparent !important;
      padding: 0 var(--vt-gap) var(--vt-gap) 0 !important;
    }
    .browserStack {
      border-radius: var(--vt-radius-lg);
      overflow: hidden;
      border: 1px solid rgb(var(--vt-border-rgb) / 0.4);
      box-shadow: 0 8px 28px rgb(0 0 0 / 0.28);
    }
  '';

  contentFloat = (
    if G.contentFloat
    then css.toggleNeg "ting.content.dock" contentFloatBody
    else css.togglePos "ting.content.float" contentFloatBody
  );

  opaque = ''
    /* ============ 14. Escape hatch: force opaque ====================== */
    /* about:config -> ting.opaque = true                              */

    @media -moz-pref("ting.opaque") {
      :root {
        --vt-panel-alpha: 1;
        --vt-chrome-alpha: 1;
        --vt-popup-alpha: 1;
      }
      #navigator-toolbox,
      #sidebar-box,
      .urlbarView,
      findbar,
      .panel-arrowcontent {
        backdrop-filter: none !important;
      }
    }
  '';

  fullscreen = ''
    /* ============ 15. Fullscreen guards =============================== */

    :root[inFullscreen] .browserStack {
      border-radius: 0 !important;
      box-shadow: none !important;
      border: none !important;
    }
    :root[inFullscreen] #tabbrowser-tabpanels { padding: 0 !important; }
  '';
in
  findbar + statusPill + scrollbars + bookmarksBar + contentFloat + opaque + fullscreen
