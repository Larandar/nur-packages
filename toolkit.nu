# Repository maintenance: `overlay use --prefix toolkit.nu; toolkit update`.

const root = path self | path dirname

# Set by the `bash -c` that dumps the environment, not by the shell.
const dump_artifacts = [_ SHLVL PWD OLDPWD]

# Load the environment of each Nix shell into the caller's scope; later shells take precedence.
#
# `nix develop` decides what carries over, then only changed variables load. Names starting with
# a lowercase letter or `__` are derivation attributes and are dropped.
def --env with-nix-shell [
  ...installables: string # Flake installables evaluating to a shell, such as `.#nixtamal.devShell`
]: nothing -> nothing {
  for installable in $installables {
    # A file, not stdout, so shellHook output cannot corrupt the dump.
    let dump = mktemp --tmpdir with-nix-shell.XXXXXX
    try {
      ^nix develop $installable --command bash -c 'env -0 > "$0"' $dump
    } catch {|err|
      rm --force $dump
      error make {msg: $"($installable): ($err.msg)"}
    }
    let changed = open --raw $dump
    | split row (char nul)
    | compact --empty
    | parse --regex '(?s)^(?<name>[^=]+)=(?<value>.*)$'
    | where name not-in $dump_artifacts and name !~ '^([a-z]|__)'
    | where {|var| ($env | get --optional $var.name | env-string) != $var.value }
    rm $dump
    $changed
    | where name != PATH
    | reduce --fold {} {|var, acc| $acc | insert $var.name $var.value }
    | load-env
    let path = $changed | where name == PATH | get --optional 0.value
    if $path != null { $env.PATH = $path | split row (char esep) }
  }
}

# An environment value as an external process receives it.
def env-string []: any -> any {
  let value = $in
  if ($value | describe) =~ '^list' { $value | str join (char esep) } else { $value }
}

# Load the repository tooling (`default.devShell`), then the `devShell` of each named package, into the caller's scope.
export alias load-shell = do --env {|...packages: string|
  with-nix-shell $"($root)#default.devShell" ...($packages | each {|package| $"($root)#($package).devShell" })
}

# Lock new nixtamal inputs, then refresh every unfrozen pin to the value its fresh-cmd reports.
@example "Refresh every pin" { toolkit update }
@example "Refresh only nixpkgs" { toolkit update nixpkgs }
export def update [
  ...inputs: string # Inputs to refresh; all unfrozen inputs when omitted
]: nothing -> nothing {
  cd $root
  load-shell
  ^nixtamal lock
  ^nixtamal refresh ...$inputs
}
