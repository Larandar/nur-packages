{
  callPackage,
  openssl,
  src,
  # The pin's version; plugins version themselves by crate and Nushell instead.
  version,
}:
callPackage ../nushell-plugins/builder.nix {
  inherit src;
  crate = "nu_plugin_ws";
  description = "WebSocket client commands for Nushell";
  homepage = "https://github.com/alex-kattathra-johnson/nu_plugin_ws";
  license = "mit";
  buildInputs = [openssl];
  lockFile = ./Cargo.lock;
  rules = ./rules;
}
