# The aspect tree: one file per aspect, the path IS the address, and every file
# becomes a `clan.modules.<dotted>` entry so an inventory instance names it with
# `module.input = "self"`. clan.nix registers the tree; nothing registers a file.
#
#   modules/aspects/desktop/gnome.nix        → clan.modules."desktop.gnome"
#   modules/aspects/base/default.nix         → clan.modules.base
#   modules/aspects/base/persistence.nix     → clan.modules.base.persistence
#   modules/aspects/_lib.nix                 → nothing; a helper aspects import
#   modules/aspects/desktop/(no default.nix) → nothing; a category is a prefix
#
# A file returns `{description, categories?, readme?, nixos?, darwin?}` and this
# library phrases it as a clan service. A file that already returns a
# `clan.service` module is passed through with its manifest completed, so an
# aspect with a typed `interface` and per-machine `settings` keeps writing them
# long-hand instead of losing them to a shorthand.
{lib}: let
  address = import ./address.nix {inherit lib;};
  none = {};
  firstOf = candidates: lib.findFirst (x: x != null) null candidates;

  # Every regular `.nix` file under `root`, as segments relative to it.
  filesUnder = root: let
    go = prefix: dir:
      lib.concatLists (lib.mapAttrsToList (
        name: kind:
          if kind == "directory"
          then go (prefix ++ [name]) "${toString dir}/${name}"
          else if lib.hasSuffix ".nix" name
          then [(prefix ++ [name])]
          else []
      ) (builtins.readDir dir));
  in
    go [] (toString root);

  pathOf = root: segments: "${toString root}/${lib.concatStringsSep "/" segments}";
in rec {
  mkTree = {
    src,
    defaults ? {},
  }: let
    entries = map (segments: {
      key = address.addressOf segments;
      path = pathOf src segments;
    }) (lib.filter (s: !address.isHelper s) (filesUnder src));

    named = lib.filter (e: e.key != "") entries;
    # A `default.nix` at the root names the collection, not an aspect in it.
    atRoot = lib.filter (e: e.key == "") entries;
    collisions = lib.filterAttrs (_: es: lib.length es > 1) (lib.groupBy (e: e.key) named);

    refusals =
      map (e: "'${e.path}' is a default.nix at the tree root, so it names the collection rather than an aspect in it") atRoot
      ++ map (k: "two files name the aspect '${k}': ${lib.concatMapStringsSep ", " (e: "'${e.path}'") collisions.${k}}") (lib.attrNames collisions);

    gate =
      if refusals == []
      then null
      else throw (lib.concatLines refusals);

    # A file is applied only to the formals it names, so `{...}:`, `{lib, ...}:`
    # and `{ }:` all work and a typo (`{lob}:`) is a missing-argument error
    # rather than a silent null.
    applyFile = e: let
      body = import e.path;
      supplied = {
        inherit lib;
        name = e.key;
        address = e.key;
      };
    in
      if lib.isFunction body
      then body (builtins.intersectAttrs (builtins.functionArgs body) supplied)
      else body;

    readmeOf = e: let
      p = "${dirOf e.path}/README.md";
    in
      if builtins.pathExists p
      then builtins.readFile p
      else "";

    serviceOf = e: let
      body = applyFile e;
      m = body.manifest or none;
      nixos = body.nixos or null;
      darwin = body.darwin or null;
      # A class the aspect does not configure is absent, not an empty module: an
      # aspect may be NixOS-only, and saying so by omission keeps a darwin
      # machine from composing a module that has nothing to say.
      synthRoles = {
        default = {
          description = "Whatever the aspect declares, and nothing else.";
          perInstance = _:
            lib.optionalAttrs (nixos != null) {nixosModule = nixos;}
            // lib.optionalAttrs (darwin != null) {darwinModule = darwin;};
        };
      };
    in {
      _class = "clan.service";
      manifest = {
        name = firstOf [(m.name or null) e.key];
        description = firstOf [(m.description or null) (body.description or null) "No description"];
        readme = firstOf [(m.readme or null) (body.readme or null) (readmeOf e) ""];
        categories = firstOf [
          (m.categories or null)
          (body.categories or null)
          (defaults.categories or null)
          ["Uncategorized"]
        ];
      };
      roles = body.roles or synthRoles;
    };
  in
    builtins.seq gate {
      modules = lib.listToAttrs (map (e: {
          name = e.key;
          value = serviceOf e;
        })
        named);
      addresses = map (e: e.key) named;
    };

  # Just the `clan.modules` half, for the one-line call in clan.nix.
  mkModules = args: (mkTree args).modules;
}
