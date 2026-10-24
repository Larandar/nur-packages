{pkgs ? import <nixpkgs> {}}:
with builtins; let
  isDerivation = p: isAttrs p && p ? type && p.type == "derivation";
  isBuildable = p: let
    licenseFromMeta = p.meta.license or [];
    licenseList =
      if builtins.isList licenseFromMeta
      then licenseFromMeta
      else [licenseFromMeta];
  in
    !(p.meta.broken or false) && builtins.all (license: license.free or true) licenseList;
  isCacheable = p: !(p.preferLocalBuild or false);
  shouldRecurseForDerivations = p: isAttrs p && p.recurseForDerivations or false;

  concatMap = builtins.concatMap or (f: xs: concatLists (map f xs));

  flattenPkgs = s: let
    f = p:
      if shouldRecurseForDerivations p
      then flattenPkgs p
      else if isDerivation p
      then [p]
      else [];
  in
    concatMap f (attrValues s);

  outputsOf = p: map (o: p.${o}) p.outputs;

  nurPkgs = flattenPkgs (import ./overlay.nix null pkgs);
in rec {
  buildPkgs = filter isBuildable nurPkgs;
  cachePkgs = filter isCacheable buildPkgs;

  buildOutputs = concatMap outputsOf buildPkgs;
  cacheOutputs = concatMap outputsOf cachePkgs;
}
