# The chrome sections userChrome.css is composed of, in order. Each is a
# function of the composer's ctx; sidebery, darkreader and content are
# separate documents the composer calls on their own.
[
  (import ./chrome/base.nix)
  (import ./chrome/tabbar.nix)
  (import ./chrome/urlbar.nix)
  (import ./chrome/sidebar.nix)
  (import ./chrome/popups.nix)
  (import ./chrome/misc.nix)
]
