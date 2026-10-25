# Ting theme section — tab strip: hide the native bar, float window
# controls over the nav bar (safari-firefox style).
#
# composer decisions:
#   M.hideTabBar  -> native strip collapsed, but wrapped in a NEGATIVE
#                    toggle so `ting.tabbar.show = true` restores it.
#   WC == "float" -> traffic lights / CSD buttons hover over the nav bar
#                    (only meaningful together with hideTabBar).
#   WC == "none"  -> controls removed entirely (WM draws decorations).
#   WC == "titlebar" -> nothing here; the module sets browser.tabs.inTitlebar=0.
ctx: let
  inherit
    (ctx)
    css
    G
    M
    WC
    ;
  inherit (css) opt toggleNeg;
in
  opt M.hideTabBar (
    toggleNeg "ting.tabbar.show" ''
      /* ============ 4. Native tab strip hidden (Sidebery replaces it) ==== */

      #TabsToolbar:not([customizing]) {
        height: 0 !important;
        min-height: 0 !important;
        max-height: 0 !important;
        padding: 0 !important;
        margin: 0 !important;
        overflow: visible; /* floated window controls remain visible */
        position: relative;
      }
      #TabsToolbar:not([customizing]) .toolbar-items,
      #TabsToolbar:not([customizing]) .titlebar-spacer,
      #TabsToolbar:not([customizing]) #firefox-view-button {
        display: none !important;
      }
    ''
  )
  + opt (WC == "float" && M.hideTabBar) ''
    /* ======== 5. Window controls float over the nav bar (Safari-like) === */

    #TabsToolbar .titlebar-buttonbox-container {
      position: absolute !important;
      top: 0 !important;
      height: var(--vt-nav-h) !important;
      z-index: 1000;
      -moz-window-dragging: no-drag;
    }
    .titlebar-buttonbox {
      -moz-window-dragging: no-drag;
    }

    @media (-moz-platform: macos) {
      #TabsToolbar .titlebar-buttonbox-container {
        left: 10px !important;
        right: auto !important;
      }
      /* keep clear of the traffic lights */
      #nav-bar { padding-left: 84px !important; }
    }

    @media (-moz-platform: linux), (-moz-platform: windows) {
      #TabsToolbar .titlebar-buttonbox-container {
        right: 6px !important;
        left: auto !important;
      }
      /* keep clear of the CSD close/min/max cluster */
      #nav-bar { padding-right: 118px !important; }
    }
  ''
  + opt (WC == "none") ''
    /* ============== 5b. Window controls removed (WM-drawn) ============= */

    #TabsToolbar .titlebar-buttonbox-container {
      display: none !important;
    }
  ''
