# Upstream's darcs `next`, with opt-in patches and runner tools:
# `nixtamal.override {enabledPatches = ["shell"]; packages = [nushell];}`.
{
  lib,
  mkShell,
  runCommand,
  ocamlPackages,
  python3Packages,
  nushell,
  testers,
  nixtamal,
  src,
  enabledPatches ? [],
  # Tools put first on the runner's PATH, for `fresh-cmd` pipelines and `shell=`; the caller's PATH follows.
  packages ? [],
}: let
  available = {
    # `fresh-cmd shell="nu"` runs the pipeline through a shell; from midgard-flakes, rebased onto `next`.
    shell = ./patches/nixtamal-shell.patch;
  };

  unknown = lib.subtractLists (lib.attrNames available) enabledPatches;
  disabled = lib.subtractLists enabledPatches (lib.attrNames available);
  shell = lib.elem "shell" enabledPatches;

  wrapper = ''wrapProgram "$bin/bin/nixtamal" --prefix PATH : '';

  package = nixtamal.overrideAttrs (finalAttrs: prev:
    {
      # Forced only when the derivation is used, so `.override` on the default stays quiet.
      version = let
        darcs = builtins.elemAt (lib.importJSON ../../nix/tamal/lock.json).i.nixtamal.kd 1;
        version = lib.concatStringsSep "-" (["2.3.0-unstable-${builtins.substring 0 10 darcs.dt}"] ++ enabledPatches);
      in
        if disabled == []
        then version
        else lib.info "nixtamal: optional patches not enabled: ${toString disabled}; enable with `nixtamal.override {enabledPatches = [...];}`" version;

      inherit src;

      patches = (prev.patches or []) ++ map (name: available.${name}) enabledPatches;

      passthru =
        prev.passthru
        // {
          tests =
            {
              version = testers.testVersion {
                package = finalAttrs.finalPackage.bin;
                command = "nixtamal --version";
              };
            }
            // lib.optionalAttrs (shell && lib.any (package: lib.getName package == "nushell") packages) {
              shell = runCommand "nixtamal-shell-test" {} ''
                export HOME="$TMPDIR"
                ${lib.getExe nushell} --no-config-file ${./tests/shell.nu} ${lib.getExe finalAttrs.finalPackage.bin}
                touch "$out"
              '';
            };

          # Enough for `dune build`; `lib/dune` preprocesses with ppx_deriving_qcheck, and `doc/dune` runs rst2man.
          devShell = mkShell {
            nativeBuildInputs = [
              ocamlPackages.ocaml
              ocamlPackages.dune_3
              ocamlPackages.findlib
              ocamlPackages.ppx_deriving
              ocamlPackages.ppx_deriving_qcheck
              python3Packages.docutils
              python3Packages.pygments
            ];
            buildInputs = prev.buildInputs ++ prev.propagatedBuildInputs;
          };
        };
    }
    // lib.optionalAttrs shell {
      nativeCheckInputs = prev.nativeCheckInputs ++ [nushell];

      # The patch's tests run Nu, which needs a writable HOME.
      preConfigure =
        (prev.preConfigure or "")
        + ''
          export HOME="$TMPDIR"
        '';
    }
    // lib.optionalAttrs (packages != []) {
      installPhase = assert lib.hasInfix wrapper prev.installPhase;
        builtins.replaceStrings [wrapper] ["${wrapper}${lib.makeBinPath packages}:"] prev.installPhase;
    });
in
  if unknown != []
  then throw "nixtamal: unknown patches ${toString unknown}; available: ${toString (lib.attrNames available)}"
  else package
