{pkgs}: let
  mocks = map (tool:
    pkgs.writeShellScriptBin tool ''
      exec ${pkgs.lib.getExe pkgs.nushell} --no-config-file ${./fixtures/workflow/mock.nu} ${tool} "$@"
    '') [ "nix" "nixtamal" "iets" "gh" "git" ];
in
  pkgs.runCommand "workflow-test" {
    nativeBuildInputs = mocks ++ [pkgs.git pkgs.jujutsu pkgs.nushell];
  } ''
    export HOME="$TMPDIR/home"
    export REAL_GIT=${pkgs.lib.getExe pkgs.git}
    mkdir -p "$HOME" checkout/nix
    cp ${../toolkit.nu} checkout/toolkit.nu
    cp ${../nix/github.nu} checkout/nix/github.nu
    cp ${./fixtures/workflow/test.nu} checkout/test.nu
    cd checkout
    nu --no-config-file test.nu
    touch "$out"
  ''
