# Waterfox, its settings baked into the install by the shared Mozilla wrapper; `.override` takes them (see
# ../mozilla/wrap.nix).
{
  lib,
  callPackage,
  src,
  version,
  # Named apart from the overlay's `waterfox-unwrapped`, which is this package's `unwrapped`.
  unwrapped ? callPackage ./unwrapped.nix {inherit src version;},
  # home-manager's source, for the module tests; null leaves them out.
  homeManager ? null,
  # Declared so home-manager's Firefox modules see the wrapFirefox interface (they test for `cfg`); passed through.
  cfg ? {},
  extraPolicies ? {},
  extraPrefs ? "",
  extraPrefsFiles ? [],
  nativeMessagingHosts ? [],
  pkcs11Modules ? [],
  ...
} @ settings:
callPackage ../mozilla/wrap.nix (removeAttrs settings ["lib" "callPackage" "src" "version" "homeManager"]
  // {
    inherit unwrapped;
    binaryName = "waterfox";
    applicationName = "Waterfox";
    passthru = {
      # Release notes come from the GitHub repository whose tags the pin follows; the binary comes from Waterfox's CDN.
      upstreamRepository = "https://github.com/BrowserWorks/waterfox";
      tests = lib.optionalAttrs (homeManager != null) (removeAttrs (callPackage ./tests.nix {inherit homeManager;}) ["override" "overrideDerivation"]);
    };
  })
