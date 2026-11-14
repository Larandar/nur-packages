# Ting — the composed theme pack (ultraviolet): share/ting/ holds everything
# ready to copy into a profile's chrome/ directory. The waterfox modules'
# `theme = "ting"` composes it for their own palette (see ./README.md).
{
  lib,
  symlinkJoin,
  writeTextDir,
  runCommand,
  nushell,
}: let
  tingLib = import ./lib {inherit lib;};
  out = tingLib.composer.compose {};
in
  symlinkJoin {
    name = "ting-${out.meta.version}";
    paths = [
      (writeTextDir "share/ting/chrome/userChrome.css" out.userChrome)
      (writeTextDir "share/ting/chrome/palette.css" out.paletteCss)
      (writeTextDir "share/ting/chrome/userContent.css" out.userContentCss)
      (writeTextDir "share/ting/sidebery/sidebery.css" out.sidebery.css)
      (writeTextDir "share/ting/sidebery/sidebery.json" out.sidebery.json)
      (writeTextDir "share/ting/README.md" (builtins.readFile ./README.md))
    ];
    passthru = {
      inherit
        (out)
        userChrome
        paletteCss
        userContentCss
        sidebery
        meta
        ;
      composer = tingLib.composer;
      palettes = tingLib.palettes;
      # The theme's own checks: the structural validator and the timepalette smoke test.
      tests.checks = runCommand "ting-chrome-checks" {nativeBuildInputs = [nushell];} ''
        cp -r ${./.} ting
        chmod -R u+w ting
        HOME=$TMPDIR nu ting/checks/validate_ting.nu
        HOME=$TMPDIR nu ting/checks/test_timepalette.nu
        touch $out
      '';
    };
    meta = with lib; {
      description = "Glassmorphic Firefox chrome composed in nix (Wayland + macOS)";
      longDescription = ''
        Ting blends EdgyArc-fr's Edge-style sidebar, FF-ULTIMA's composer
        minimalism, TransparentFox/Glass-Firefox glassmorphism, natsumi's
        floating URL bar, FoxOne's floating content, safari-firefox window
        controls, a DarkReader-style content theming engine and a full
        Sidebery v5 companion — packaged as a nix flake.
      '';
      license = licenses.mit;
      platforms = platforms.unix;
    };
  }
