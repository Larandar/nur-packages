# waterfox-remote: one daemon per user holding each Waterfox profile's WebDriver BiDi session, served over Varlink
# (`ad.lar.WaterfoxRemote`), D-Bus and, optionally, MCP. The crate is this repository's own; programs.waterfox.remote
# (modules/waterfox/remote.nix) runs it.
{
  lib,
  rustPlatform,
  runCommand,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "waterfox-remote";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;

  # Its subcommands, as the module and the launcher call them.
  passthru.tests.help = runCommand "waterfox-remote-help" {} ''
    ${lib.getExe finalAttrs.finalPackage} --help | grep -qw daemon
    ${lib.getExe finalAttrs.finalPackage} --help | grep -qw mcp
    touch $out
  '';

  meta = {
    description = "Waterfox and the desktop launcher, both ways, over WebDriver BiDi";
    license = lib.licenses.mpl20;
    mainProgram = "waterfox-remote";
    platforms = lib.platforms.unix;
  };
})
