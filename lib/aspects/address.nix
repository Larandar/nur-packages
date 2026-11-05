# Path → address for the aspect tree: the pure half, so the law can be pinned
# with fixture strings and no evaluation. A path's segments are its address;
# `.nix` is not part of a name, and `default.nix` names the directory holding
# it — which is why `x/default.nix` and `x.nix` name the same aspect and may
# not both exist.
{lib}: let
  # Takes a path string or an already-split segment list. A list must not go
  # through toString: it joins with spaces, and "a b" is one segment, not two.
  segmentsOf = p:
    if lib.isList p
    then p
    else lib.filter (s: s != "") (lib.splitString "/" (toString p));
in rec {
  # The segments a path names, file layer removed. `[]` means the tree root.
  namedOf = relPath: let
    segments = map (s: lib.removeSuffix ".nix" s) (segmentsOf relPath);
  in
    if segments != [] && lib.last segments == "default"
    then lib.init segments
    else segments;

  # The dotted key the path derives; "" for a path that names the tree root.
  addressOf = relPath: lib.concatStringsSep "." (namedOf relPath);

  # A `_`-prefixed file is machinery an aspect imports, never an aspect: it
  # registers nothing, and no instance may bind it.
  isHelper = relPath: lib.hasPrefix "_" (baseNameOf (toString relPath));
}
