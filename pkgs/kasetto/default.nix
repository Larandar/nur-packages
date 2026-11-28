{
  lib,
  rustPlatform,
  src,
  version,
}:
rustPlatform.buildRustPackage {
  pname = "kasetto";
  inherit src version;

  inherit (import ./lock.nix) cargoHash;

  meta = {
    description = "Declarative AI agent environment manager";
    homepage = "https://kasetto.dev";
    license = with lib.licenses; [mit asl20];
    mainProgram = "kasetto";
  };
}
