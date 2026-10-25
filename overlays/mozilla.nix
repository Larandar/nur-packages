# Waterfox and nixpkgs' LibreWolf with their settings baked into the install: `.override { policies; preferences;
# extensions; chrome; ... }` on either (see pkgs/mozilla/wrap.nix). LibreWolf is this nixpkgs' `librewolf-unwrapped`,
# its own preferences and policies kept beneath the settings; the overlay replaces `librewolf`.
final: prev: let
  nur = import ../default.nix {pkgs = prev;};
in {
  inherit (nur) waterfox waterfox-unwrapped;
  librewolf = final.callPackage ../pkgs/mozilla/wrap.nix {
    unwrapped = prev.librewolf-unwrapped;
    binaryName = "librewolf";
    applicationName = "LibreWolf";
    basePreferenceFiles = prev.librewolf-unwrapped.extraPrefsFiles;
    basePolicyFiles = prev.librewolf-unwrapped.extraPoliciesFiles;
  };
}
