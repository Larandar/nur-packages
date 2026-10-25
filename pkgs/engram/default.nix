{
  lib,
  buildGoModule,
  git,
  src,
  version,
}:
buildGoModule (finalAttrs: {
  pname = "engram";
  inherit src version;

  inherit (import ./lock.nix) vendorHash;

  subPackages = ["cmd/engram"];

  # `cmd/engram`'s doctor tests run `git init` in a temporary directory.
  nativeCheckInputs = [git];

  # Tests that build a second binary force `-mod=readonly`, which needs a module cache the sandbox
  # lacks; the vendored modules serve them instead.
  postPatch = ''
    substituteInPlace cmd/engram/compatibility_test.go \
      --replace-fail '"GOFLAGS=-mod=readonly"' '"GOFLAGS=-mod=vendor"'
  '';

  # `main.version` otherwise reads "dev". Upstream's update check skips `mcp` and `serve`.
  ldflags = [
    "-s"
    "-w"
    "-X main.version=${finalAttrs.version}"
  ];

  meta = {
    description = "Local-first memory for coding agents, over one SQLite file";
    homepage = "https://github.com/Gentleman-Programming/engram";
    license = lib.licenses.mit;
    mainProgram = "engram";
  };
})
