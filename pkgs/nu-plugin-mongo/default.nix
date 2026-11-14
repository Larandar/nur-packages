{
  callPackage,
  openssl,
  src,
  # The pin's version; plugins version themselves by crate and Nushell instead.
  version,
}:
callPackage ../nushell-plugins/builder.nix {
  inherit src;
  crate = "nu_plugin_mongo";
  description = "MongoDB commands for Nushell";
  homepage = "https://github.com/WindSoilder/nu_plugin_mongo";
  license = "mit";
  buildInputs = [openssl];
  lockFile = ./Cargo.lock;
  rules = ./rules;
}
