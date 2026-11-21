# Point a Nushell plugin's source at one exact Nushell release.
#
# A plugin loads only in the Nushell it was compiled for, so every dependency
# on a crate Nushell itself publishes — `nu-plugin`, `nu-protocol` and the
# rest of the `nu-*` family that shares its version — is pinned to exactly
# that release, whatever upstream's manifest asked for. Then the ast-grep
# rules beside this file are applied: source changes a Nushell release
# forces on the plugin, one rule per change.
#
# Edits the tree in place. Run on a writable copy of the pinned source.

# The crates released in lockstep with the shell. A plugin may depend on
# other `nu-`-prefixed crates of its own; only these follow the shell.
const NUSHELL_CRATES = [
    nu-plugin nu-protocol nu-plugin-test-support nu-plugin-core nu-plugin-protocol nu-plugin-engine
    nu-engine nu-path nu-utils nu-system nu-glob nu-derive-value nu-cmd-base nu-cmd-lang
    nu-command nu-parser nu-color-config nu-table nu-json nu-pretty-hex nu-term-grid nu-test-support
]

# One dependency table with its Nushell crates set to `=version`. A bare
# string becomes the exact requirement; a table keeps its features and
# other keys, and loses any `path` or `git` that would bypass the release.
def pin-table [version: string]: record -> record {
    $in | items {|name, spec|
        let pinned = if $name not-in $NUSHELL_CRATES {
            $spec
        } else if ($spec | describe) == "string" {
            $"=($version)"
        } else {
            $spec | reject --optional path git branch tag rev | upsert version $"=($version)"
        }
        {name: $name, spec: $pinned}
    } | reduce --fold {} {|row, table| $table | insert $row.name $row.spec }
}

# Rewrite the manifest and apply the rules.
def main [
    source: path   # a writable copy of the plugin's source
    version: string  # the Nushell release to compile for, as `0.116.0`
    rules: path    # a directory of ast-grep rule files, possibly without any
]: nothing -> nothing {
    if $version !~ '^\d+\.\d+\.\d+$' {
        error make {msg: $"Not a Nushell release version: ($version)"}
    }
    let manifest = $source | path join Cargo.toml
    let before = open $manifest
    let tables = [dependencies dev-dependencies build-dependencies]
    let after = $tables | reduce --fold $before {|table, manifest|
        if $table in $manifest {
            $manifest | update $table {|m| $m | get $table | pin-table $version }
        } else {
            $manifest
        }
    }
    let pinned = $tables | each {|table| $after | get --optional $table | default {} | columns | where $it in $NUSHELL_CRATES } | flatten | uniq
    if "nu-plugin" not-in $pinned {
        error make {msg: $"($manifest) does not depend on nu-plugin: not a Nushell plugin, or its manifest moved"}
    }
    $after | to toml | save --force $manifest
    print --stderr $"pinned to Nushell ($version): ($pinned | sort | str join ', ')"

    for rule in (glob ($rules | path join "*.yml") | sort) {
        let applied = ^ast-grep scan --rule $rule --update-all $source | complete
        if $applied.exit_code != 0 {
            error make {msg: $"ast-grep rule ($rule | path basename) failed: ($applied.stderr | str trim)"}
        }
        # ast-grep exits 0 and says nothing when a rule matches nothing. A
        # rule that no longer matches is upstream having made the change, or
        # having moved the code: either way the file is stale and is deleted
        # or rewritten, never left to read as a patch that is being applied.
        let changes = ($"($applied.stdout)\n($applied.stderr)" | parse --regex 'Applied (?<count>\d+) changes' | get count | into int | append 0 | math sum)
        if $changes == 0 {
            error make {msg: $"ast-grep rule ($rule | path basename) matched nothing in ($source): delete it, or fix it"}
        }
        print --stderr $"applied ($rule | path basename): ($changes) changes"
    }
}
