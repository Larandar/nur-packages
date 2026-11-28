# The aspect tree's law, as cases: a key derives from a path, a category
# registers nothing, a `_` helper registers nothing, and two files naming one
# aspect is refused.
{
  pkgs,
  aspects,
}: let
  inherit (pkgs) lib;
  tree = aspects.mkModules {src = ./fixtures/aspects;};
  keys = lib.attrNames tree;
  expected = ["alpha" "group.beta" "group.beta.gamma" "group.plain"];
  # tryEval catches a throw, not an assertion, and its result is a set, so
  # the test is on the boolean it carries.
  refused = path: let
    r = builtins.tryEval (builtins.deepSeq (aspects.mkModules {src = path;}) true);
  in
    !r.success;
  failures =
    lib.optional (keys != expected) "keys: want ${builtins.toJSON expected}, got ${builtins.toJSON keys}"
    ++ lib.optional (tree.alpha._class != "clan.service") "alpha: is not a clan service"
    ++ lib.optional (tree.alpha.manifest.name != "alpha") "alpha: manifest.name is not the derived address"
    ++ lib.optional (tree.alpha.manifest.description == "No description") "alpha: description was not taken from the aspect"
    ++ lib.optional (!(tree."group.beta".roles.default ? perInstance)) "group.beta: synthesised role has no perInstance"
    ++ lib.optional (tree."group.beta".manifest.name != "group.beta") "group.beta: manifest.name is not the derived address"
    ++ lib.optional (!refused ./fixtures/ambiguous) "ambiguous: x.nix beside x/default.nix was accepted";
in
  # toJSON, not toString: a list renders as "[ ]" with a space, and the
  # comparison below is against the JSON text.
  pkgs.runCommand "aspects-test" {failures = builtins.toJSON failures;} ''
    if [ "$failures" != "[]" ]; then
      echo "failed cases: $failures"
      exit 1
    fi
    echo "aspects: all cases passed"
    touch "$out"
  ''
