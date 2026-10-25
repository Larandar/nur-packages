# Ting theme section — the sidebar that hosts Sidebery, rendered as a
# floating glass card (EdgyArc-like) over the window base.
#
# composer decisions:
#   M.hideSidebarHeader       -> the sidebar's header removed
#   M.hideFirefoxSidebarRail  -> FF 137+ icon rail removed (Sidebery replaces)
#
# Each element is named twice: the header is `#sidebar-header` in the old
# sidebar and `#sidebar-panel-header` inside the revamped panel's own
# document; the rail is `#sidebar-main` before Gecko 153 and an id-less
# `<sidebar-main>` in `#sidebar-container` from it.
#   G.sidebarFloat = true  -> glass card, escape hatch ting.sidebar.dock
#   G.sidebarFloat = false -> docked by default, enabled by
#                             ting.sidebar.float
ctx: let
  inherit (ctx) css G M;

  common = ''
    /* ============ 7. Sidebar (Sidebery host) ========================== */

    #sidebar,
    #sidebar-main,
    sidebar-main {
      background-color: transparent !important;
      border: none !important;
    }
    #sidebar {
      background-color: transparent !important;
    }
    /* legacy splitter has no place in a floating layout */
    #sidebar-splitter { display: none !important; }
  '';

  headerCss = (
    if M.hideSidebarHeader
    then ''
      #sidebar-header,
      #sidebar-panel-header { display: none !important; }
    ''
    else ''
      #sidebar-header,
      #sidebar-panel-header {
        background-color: transparent !important;
        border-bottom: 1px solid rgb(var(--vt-border-rgb) / 0.4) !important;
      }
      #sidebar-header #sidebar-switcher-target:hover {
        background-color: rgb(var(--vt-text-rgb) / 0.08);
        border-radius: var(--vt-radius-sm);
      }
    ''
  );

  railCss = (
    if M.hideFirefoxSidebarRail
    then ''
      /* FF 137+ unified-sidebar icon rail — Sidebery replaces it */
      #sidebar-main,
      #sidebar-container:has(> sidebar-main) { display: none !important; }
    ''
    else ''
      #sidebar-main,
      sidebar-main {
        background-color: transparent !important;
        border: none !important;
      }
    ''
  );

  floatBody = ''
    /* floating glass card */
    #sidebar-box {
      background-color: rgb(var(--vt-surface-rgb) / var(--vt-panel-alpha, 0.72)) !important;
      backdrop-filter: blur(var(--vt-blur)) saturate(1.3);
      border-radius: var(--vt-radius-lg) !important;
      border: 1px solid rgb(var(--vt-border-rgb) / 0.55) !important;
      box-shadow: 0 10px 34px rgb(0 0 0 / 0.32);
      margin: var(--vt-gap) !important;
      overflow: hidden;
    }
  '';
in
  common
  + headerCss
  + railCss
  + (
    if G.sidebarFloat
    then css.toggleNeg "ting.sidebar.dock" floatBody
    else css.togglePos "ting.sidebar.float" floatBody
  )
