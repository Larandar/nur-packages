{
  lib,
  vimUtils,
  src,
  version,
}:
vimUtils.buildVimPlugin {
  pname = "neocursor-nvim";
  inherit src version;

  meta = {
    description = "Cursor's Tab next-edit predictions in Neovim";
    homepage = "https://github.com/teocns/neocursor.nvim";
    license = lib.licenses.mit;
  };
}
