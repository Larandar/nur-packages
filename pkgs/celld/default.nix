# celld's binaries as a set: one row in `components` per workspace crate this package ships.
{
  lib,
  rustPlatform,
  makeWrapper,
  esbuild,
  src,
  version,
  rustyV8,
  rustyV8Version,
}: let
  # rusty_v8's build script downloads a prebuilt static V8; the companion input pins it, and it must be the version
  # the source's Cargo.lock locks.
  lockedV8 = (lib.findFirst (package: package.name == "v8") null (lib.importTOML "${src}/Cargo.lock").package).version;
  archive =
    lib.throwIfNot (lockedV8 == rustyV8Version)
    "celld: Cargo.lock locks v8 ${lockedV8}, but celld-rusty-v8 pins ${rustyV8Version}; run `toolkit update` or `toolkit nightly celld`"
    rustyV8;

  # One vendored dependency set serves every component.
  cargoDeps = rustPlatform.fetchCargoVendor {
    name = "celld-${version}-vendor";
    inherit src;
    hash = (lib.importJSON ./lock.nuon).cargoHash;
  };

  component = {
    crate,
    mainProgram,
    description,
    postInstall ? "",
  }:
    rustPlatform.buildRustPackage {
      pname = crate;
      inherit version src cargoDeps postInstall;

      cargoBuildFlags = ["-p" crate];
      cargoTestFlags = ["-p" crate];

      RUSTY_V8_ARCHIVE = archive;

      nativeBuildInputs = [makeWrapper];

      meta = {
        inherit description mainProgram;
        homepage = "https://celld.dev";
        license = lib.licenses.mit;
        # The pinned rusty_v8 archive is the x86_64 Linux build.
        platforms = ["x86_64-linux"];
      };
    };
in
  lib.recurseIntoAttrs {
    daemon = component {
      crate = "celld";
      mainProgram = "celld";
      description = "Self-hosted, distributed Durable Objects: Cloudflare Workers applications and stateful primitives on your own infrastructure";
      # `celld deploy` bundles Worker projects with the esbuild on PATH.
      postInstall = ''
        wrapProgram $out/bin/celld --prefix PATH : ${lib.makeBinPath [esbuild]}
      '';
    };
  }
