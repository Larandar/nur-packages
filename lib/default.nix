{pkgs}: {
  # The Ting chrome theme's composer, palettes, stylix bridge, preferences and chrome files (pkgs/ting-chrome).
  ting = import ../pkgs/ting-chrome/lib {inherit (pkgs) lib;};
}
