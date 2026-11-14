# Snix's binaries as a set: one row in `components` per workspace crate this package ships.
{
  lib,
  rustPlatform,
  protobuf,
  busybox-sandbox-shell,
  src,
  version,
}: let
  # The Rust workspace is the monorepo's `snix/` directory; the source unpacks under its store name.
  sourceRoot = "${builtins.substring 33 (-1) (baseNameOf (toString src))}/snix";

  # One vendored dependency set serves every component.
  cargoDeps = rustPlatform.fetchCargoVendor {
    name = "snix-${version}-vendor";
    inherit src sourceRoot;
    hash = (import ./lock.nix).cargoHash;
  };

  component = {
    crate,
    features ? [],
    env ? {},
    mainProgram,
    description,
  }:
    rustPlatform.buildRustPackage {
      pname = crate;
      inherit version src sourceRoot cargoDeps;

      cargoBuildFlags = ["-p" crate] ++ lib.concatMap (feature: ["--features" feature]) features;

      inherit env;

      # Several workspace members pull test dependencies this package does not ship; upstream tests per crate.
      doCheck = false;

      # prost-build runs protoc for the store's gRPC definitions.
      nativeBuildInputs = [protobuf];

      meta = {
        inherit description mainProgram;
        homepage = "https://snix.dev";
        license = lib.licenses.mit;
      };
    };
in
  lib.recurseIntoAttrs {
    # The binary-cache pair (snix.dev/docs/guides/binary-cache); its composition settings need the experimental
    # composition CLI.
    store = component {
      crate = "snix-cli-store";
      features = ["xp-store-composition-cli"];
      mainProgram = "snix-store";
      description = "Snix's store daemon CLI";
    };
    nar-bridge = component {
      crate = "snix-cli-nar-bridge";
      features = ["xp-store-composition-cli"];
      mainProgram = "snix-nar-bridge";
      description = "Snix's NAR-HTTP bridge";
    };
    # The Nix daemon protocol over a snix store: path info and NARs (query,
    # add, read). Builds, QueryMissing and GC roots are not implemented
    # upstream, so it stands as the lower store of a local-overlay Nix store
    # (snix.dev/docs/guides/local-overlay), not as a machine's only daemon.
    nix-daemon = component {
      crate = "snix-cli-nix-daemon";
      mainProgram = "snix-nix-daemon";
      # snix-build reads the shell its OCI and bwrap sandboxes start from at
      # compile time, as upstream builds it.
      env.SNIX_BUILD_SANDBOX_SHELL = "${busybox-sandbox-shell}/bin/busybox";
      description = "Snix's Nix daemon protocol server (store reads and NAR transfer; no builds)";
    };
  }
