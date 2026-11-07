# vproxy: a SOCKS5/HTTP proxy that draws every connection's source address from a CIDR, with a fallback (an address
# or an interface) for what that family cannot reach. By the author of wreq, which SearchWala runs on; the search exits
# fan out over their /64 with it. The pin is the published crate: the repository's tags carry no Cargo.lock.
{
  lib,
  rustPlatform,
  runCommand,
  src,
  version,
}:
rustPlatform.buildRustPackage (finalAttrs: {
  pname = "vproxy";
  inherit src version;
  cargoLock.lockFile = "${src}/Cargo.lock";
  # Its tests open sockets and reach the network the sandbox does not have.
  doCheck = false;

  passthru = {
    # Release notes come from the GitHub repository whose tags the pin follows; the source from crates.io.
    upstreamRepository = "https://github.com/0x676e67/vproxy";
    tests.version = runCommand "vproxy-version" {} ''
      ${lib.getExe finalAttrs.finalPackage} --version | grep -qF ${lib.escapeShellArg finalAttrs.version}
      touch $out
    '';
  };

  meta = {
    description = "SOCKS5/HTTP proxy with a random source address per connection from a CIDR";
    homepage = "https://github.com/0x676e67/vproxy";
    license = lib.licenses.gpl3Only;
    mainProgram = "vproxy";
    platforms = lib.platforms.linux;
  };
})
