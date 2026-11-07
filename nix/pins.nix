# Pinned sources, and the versions they name, from nixtamal's lock.
{pkgs}: let
  inherit (pkgs) lib;
  lock = lib.importJSON ./tamal/lock.json;
  locked = name: lock.i.${name} or (throw "nix/pins.nix: no nixtamal input `${name}`");

  # nixtamal's lock encodes an input's kind as the first element of `kd`.
  archive = 1;
  isArchive = name: builtins.head (locked name).kd == archive;
  date = name: builtins.substring 0 10 (builtins.elemAt (locked name).kd 1).dt;

  inputs = import ./tamal {bootstrap-pkgs = pkgs;};
in {
  inherit inputs;

  # Package `name` from input `name`. On `main` the input is a release archive whose fresh value is the
  # tag; a `<name>/nightly` branch re-points it at upstream's branch, versioned from the release
  # `lock.nix` records. `extra` adds arguments beyond `src` and `version`.
  # The check sits in `src`, which only building forces: listing the attributes never fails.
  package = name: path: extra: let
    lockFile = path + "/lock.nix";
    recorded = (import lockFile).tag or null;
    fresh =
      !isArchive name
      || !builtins.pathExists lockFile
      || lib.assertMsg (recorded == (locked name).fv)
      "${name}: lock.nix holds hashes for ${
        if recorded == null
        then "no tag"
        else recorded
      }, but the pin is ${(locked name).fv}; run `toolkit check --fix ${name}`";
    version =
      if isArchive name
      then lib.removePrefix "v" (locked name).fv
      else "${
        if recorded == null
        then "0"
        else lib.removePrefix "v" recorded
      }-unstable-${date name}";
  in
    pkgs.callPackage path ({
        src = assert fresh; inputs.${name};
        inherit version;
      }
      // extra);
}
