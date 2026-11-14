# searchwala-calf: the crate in ./crate over SearchWala's search pipeline, a path dependency on the pin's release,
# assembled beside the crate (so the pin, not a registry, decides what the door runs); ./page is its start page.
{
  lib,
  stdenv,
  rustPlatform,
  runCommand,
  cmake,
  git,
  perl,
  llvmPackages,
  glibc,
  curl,
  callPackage,
  src,
  version,
  # nix-darwin's source, for the darwin module test; null leaves it out.
  nixDarwin ? null,
}: let
  # The crate beside SearchWala, as the crate's `path = "../vendor-searchwala"` expects.
  assembled = runCommand "searchwala-calf-src" {} ''
    mkdir -p $out
    cp -r ${./crate} $out/searchwala-calf
    cp -r ${src} $out/vendor-searchwala
    chmod -R u+w $out
  '';
in
  rustPlatform.buildRustPackage (finalAttrs: {
    pname = "searchwala-calf";
    inherit version;
    src = assembled;
    buildAndTestSubdir = "searchwala-calf";
    # The lock sits in the crate's subdirectory; cargoSetupPostPatchHook looks for it at `$cargoRoot/Cargo.lock`.
    cargoRoot = "searchwala-calf";
    # Written against the pinned release: SearchWala is a path dependency, so the lock carries no git hashes.
    cargoLock.lockFile = ./crate/Cargo.lock;
    # wreq's BoringSSL (btls-sys) needs cmake, perl and bindgen's libc headers, and git: its build script `git init`s
    # the unpacked BoringSSL tree and `git apply`s its patches there.
    nativeBuildInputs = [
      cmake
      git
      perl
    ];
    env =
      {
        LIBCLANG_PATH = "${llvmPackages.libclang.lib}/lib";
      }
      # bindgen needs the libc headers spelled out on glibc; darwin's SDK stdenv already supplies them.
      // lib.optionalAttrs stdenv.hostPlatform.isGnu {
        BINDGEN_EXTRA_CLANG_ARGS = "-I${glibc.dev}/include";
      };

    passthru = {
      # The start page tree (an `index.html`), as a package: what a vhost roots `/` at.
      page = runCommand "searchwala-calf-page" {} "cp -r ${./page} $out";
      upstreamRepository = "https://github.com/SandeepAi369/SearchWala";
      tests =
        removeAttrs (callPackage ./tests.nix {inherit nixDarwin;}) ["override" "overrideDerivation"]
        // {
          # The engine answers on its socket: no network, so no engine is asked.
          health = runCommand "searchwala-calf-health" {nativeBuildInputs = [curl];} ''
            export HOME=$TMPDIR LISTEN_UNIX=$TMPDIR/search.sock
            ${lib.getExe finalAttrs.finalPackage} &
            for _ in $(seq 1 100); do [ -S "$LISTEN_UNIX" ] && break; sleep 0.1; done
            test "$(curl --silent --unix-socket "$LISTEN_UNIX" http://calf/health)" = ok
            kill %1
            touch $out
          '';
        };
    };

    meta = {
      description = "A lite SearchWala: its search pipeline behind one NDJSON route on a unix socket";
      homepage = "https://github.com/SandeepAi369/SearchWala";
      license = lib.licenses.mpl20;
      mainProgram = "searchwala-calf";
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
    };
  })
