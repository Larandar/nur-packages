# A Nushell plugin built against `nushell`, the shell it loads in: upstream's source with its `nu-*` dependencies
# set to exactly that release, the ast-grep rules under the plugin's `rules/` applied, and the plugin's generated
# Cargo.lock in place of upstream's (`toolkit cargo-lock` writes it).
{
  lib,
  rustPlatform,
  runCommand,
  nushell,
  ast-grep,
  pkg-config,
  src,
  crate,
  description,
  homepage,
  license,
  buildInputs ? [],
  lockFile,
  rules,
}: let
  # Versioned by what it is, not when: the crate's version and the Nushell it compiles for. The latest commit
  # that still compiles under that pair carries it.
  pluginVersion = "${(lib.importTOML "${src}/Cargo.toml").package.version}-nu-${nushell.version}";

  lockedNushell = (lib.findFirst (package: package.name == "nu-plugin") {version = null;} (lib.importTOML lockFile).package).version;

  patched =
    runCommand "${crate}-source-nu${nushell.version}" {
      nativeBuildInputs = [nushell ast-grep];
    } ''
      cp -r ${src} $out
      chmod -R u+w $out
      nu --no-config-file ${./apply.nu} $out ${nushell.version} ${rules}
      cp ${lockFile} $out/Cargo.lock
    '';
in
  rustPlatform.buildRustPackage {
    pname = crate;
    version = pluginVersion;

    src = patched;
    cargoLock = {inherit lockFile;};

    nativeBuildInputs = [pkg-config];
    inherit buildInputs;

    # Upstream's tests want a network or a display; what is checked here is that the plugin compiles for this Nushell.
    doCheck = false;

    passthru.nushellVersion = nushell.version;

    meta = {
      inherit description homepage;
      license = lib.licenses.${license};
      mainProgram = crate;
      # A plugin loads only in the Nushell it was compiled for; the lock names one.
      broken = lockedNushell != nushell.version;
    };
  }
