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
    if ($value | describe) =~ '^list' {
        $value | str join (char esep)
    } else {
        $value
    }
}

# Load the repository tooling (`default.devShell`), then the `devShell` of each named package, into the caller's scope.
export alias load-shell = do --env {|...packages: string|
  with-nix-shell $"($root)#default.devShell" ...($packages | each {|package| $"($root)#($package).devShell" })
}

# Refresh the pins `main` owns (nixpkgs, tooling, packages without releases), build, test and repair what moved,
# and commit it to `main`. Release pins move only through `toolkit release`; nightlies merge `main` when they next move.
@example "Refresh every pin main owns" { toolkit update }
@example "Refresh only nixpkgs" { toolkit update nixpkgs }
export def update [
  ...inputs: string # Inputs to refresh; every input main owns when omitted
]: nothing -> nothing {
    cd $root
    assert-on-main
    load-shell
    let released = release-packages | each {|package| [$package] ++ (companions $package) } | flatten
    let owned = open nix/tamal/lock.json | get i | columns | where $it not-in $released
    let inputs = if ($inputs | is-empty) { $owned } else { $inputs }
    let released = $inputs | where $it not-in $owned
    if ($released | is-not-empty) {
        error make {msg: $"($released | str join ', ') follow releases; use `toolkit release`"}
    }
    let before = open nix/tamal/lock.json | get i
    ^nixtamal lock --no-tui
    ^nixtamal refresh --no-tui ...$inputs
    let after = open nix/tamal/lock.json | get i
    let moved = $after | columns | where {|input| ($before | get --optional $input) != ($after | get $input) }
    if ($moved | is-empty) {
        print "Nothing moved."
        return
    }
    let packages = if "nixpkgs" in $moved { lock-packages } else { lock-packages | where $it in $moved }
    let plugins = plugin-names | where {|plugin| "nixpkgs" in $moved or $plugin in $moved }
    if ($plugins | is-not-empty) { cargo-lock ...$plugins }
    # A package whose new pin fails keeps main's: for a Nushell plugin that is the last commit that compiled for this
    # Nushell. If it fails even there, nothing is committed.
    let kept = $packages | where {|package| try { check --fix $package; false } catch { true } }
    for package in $kept {
        print $"($package): the new pin fails; keeping main's"
        transplant $package "@-"
    }
    if ($kept | is-not-empty) { check ...$kept }
    if (^jj diff --summary | str trim) == "" {
        print "Nothing moved that builds."
        return
    }
    let advanced = $moved | where $it not-in $kept
    ^jj commit --message $"Update ($advanced | str join ', ')"
    ^jj bookmark set main --revision @-
    for plugin in ($plugins | where $it in $advanced) { tag-plugin $plugin }
}

# Tag `main` for a Nushell plugin that builds there: `<plugin>/stable`, and `<plugin>/releases/<version>`, which
# moves with each newer commit that still compiles as that `<crate version>-nu-<nushell version>`.
def tag-plugin [plugin: string]: nothing -> nothing {
    let commit = commit-of main
    let version = ^nix eval --raw --file . $"($plugin).version" | str trim
    ^git tag --force $"($plugin)/stable" $commit
    ^git tag --force $"($plugin)/releases/($version)" $commit
    print $"($plugin): ($version) stable at ($commit | str substring 0..11)"
}

# nixtamal's lock encodes an input's kind as the first element of `kd`.
const archive_kind = 1

def pinned [input: string]: nothing -> record {
    open $"($root)/nix/tamal/lock.json" | get i | get $input
}

def lock-packages []: nothing -> list<string> {
    glob $"($root)/pkgs/*/lock.nuon" | each { path dirname | path basename } | sort
}

# Nushell plugins: packages whose directory carries the Cargo.lock `toolkit cargo-lock` generates.
def plugin-names []: nothing -> list<string> {
    glob $"($root)/pkgs/*/Cargo.lock" | each { path dirname | path basename } | sort
}

# Written as JSON, which is valid NUON, so Nix reads it with `lib.importJSON`.
def save-lock [file: path]: record -> nothing {
    let lock = $in
    $"($lock | to json --indent 2)\n" | save --force $file
}

const fake_hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

# Recompute each package's `lock.nuon` from scratch: per key, build with a fake hash and keep the hash Nix reports.
# A package pinned to a release archive also records the tag.
@example "Recompute engram's vendorHash" { toolkit hashes engram }
export def hashes [
  ...packages: string # Packages under pkgs/ with a lock.nuon; all of them when omitted
]: nothing -> nothing {
    cd $root
    let packages = if ($packages | is-empty) { lock-packages } else { $packages }
    for package in $packages {
        let file = $"pkgs/($package)/lock.nuon"
        let input = pinned $package
        if $input.kd.0 == $archive_kind {
            open $file | upsert tag $input.fv | save-lock $file
        }
        for key in (open $file | columns | where $it != tag) {
            let current = open $file
            $current | upsert $key $fake_hash | save-lock $file
            let build = ^nix build --no-link --file . ...(targets $package) | complete
            let got = $build.stderr | parse --regex 'got:\s+(?<hash>sha256-\S+)' | get --optional 0.hash
            if $got == null {
                $current | save-lock $file
                error make {msg: $"($package): no hash mismatch for ($key)\n($build.stderr | lines | last 20 | str join "\n")"}
            }
            $current | upsert $key $got | save-lock $file
            print $"($package).($key) = ($got)"
        }
    }
}

# Build each package, then its `passthru.tests`. A build that fails on a hash recorded in `lock.nuon` gets a
# proposed replacement, as does a release tag that no longer matches the pin; `--fix` applies them and rebuilds.
# Any other failure, or a hash recorded nowhere or in several keys, is reported, not fixed.
@example "Check engram and propose fixes" { toolkit check engram }
@example "Check and repair every package" { toolkit check --fix }
export def check [
  --fix # Apply the proposed lock.nuon changes and rebuild
  ...packages: string # Packages under pkgs/ with a lock.nuon; all of them when omitted
]: nothing -> nothing {
    cd $root
    let packages = if ($packages | is-empty) { lock-packages } else { $packages }
    let results = $packages | each {|package| check-package $package $fix }
    print ($results | table --expand)
    let open = $results | where status not-in [ok fixed]
    if ($open | is-not-empty) {
        error make {msg: $"($open | length) packages need attention: ($open | get package | str join ', ')"}
    }
}

def check-package [package: string, fix: bool]: nothing -> record {
    let file = $"pkgs/($package)/lock.nuon"
    mut changes = []
    for _ in 1..5 {
        let proposed = (lock-proposals $package $file)
        if ($proposed | is-empty) {
            let tests = targets $package | each {|target| test-attributes $target } | flatten
            let failed = $tests | where {|test| (^nix build --no-link --file . $test | complete).exit_code != 0 }
            return (if ($failed | is-empty) {
                {package: $package, status: (if ($changes | is-empty) { "ok" } else { "fixed" }), changes: $changes, detail: $"($tests | length) tests"}
            } else {
                {package: $package, status: failed, changes: $changes, detail: $"tests failed: ($failed | str join ', ')"}
            })
        }
        let failure = $proposed | where key == null
        if ($failure | is-not-empty) {
            return {package: $package, status: failed, changes: $changes, detail: $failure.0.detail}
        }
        $changes = $changes ++ ($proposed | each {|change| $"($change.key): ($change.from) -> ($change.to)" })
        if not $fix {
            return {package: $package, status: proposed, changes: $changes, detail: "run with --fix to apply"}
        }
        $proposed | reduce --fold (open $file) {|change, lock| $lock | upsert $change.key $change.to } | save-lock $file
    }
    {package: $package, status: failed, changes: $changes, detail: "still failing after 5 fixes"}
}

# What `lock.nuon` should change for `package` to build: an empty list when it builds, rows with a null key
# when it fails for a reason `lock.nuon` cannot fix.
def lock-proposals [package: string, file: path]: nothing -> list<record> {
    let entry = open $file
    let input = pinned $package
    if $input.kd.0 == $archive_kind {
        let recorded = $entry.tag? | default "none"
        if $recorded != $input.fv { return [{key: tag, from: $recorded, to: $input.fv}] }
    }
    let build = ^nix build --no-link --file . ...(targets $package) | complete
    if $build.exit_code == 0 { return [] }
    let mismatches = $build.stderr | parse --regex '(?s)specified:\s+(?<from>sha256-\S+)\s+got:\s+(?<to>sha256-\S+)'
    if ($mismatches | is-empty) {
        return [{key: null, detail: ($build.stderr | lines | last 15 | str join "\n")}]
    }
    $mismatches | each {|mismatch|
        let keys = $entry | transpose key value | where value == $mismatch.from | get key
        if ($keys | length) == 1 {
            {key: $keys.0, from: $mismatch.from, to: $mismatch.to}
        } else {
            {key: null, detail: $"($mismatch.from) is recorded in ($keys | length) lock.nuon keys, expected one"}
        }
    }
}

# What building `attribute` means: the attribute itself for a derivation, or each derivation member of a package
# set such as `snix`.
def targets [attribute: string]: nothing -> list<string> {
    let apply = 'p: if p.type or null == "derivation" then [] else builtins.filter (n: (p.${n}.type or null) == "derivation") (builtins.attrNames p)'
    let members = ^nix eval --json --file . $attribute --apply $apply | from json
    if ($members | is-empty) { [$attribute] } else { $members | each {|member| $"($attribute).($member)" } }
}

# The attribute paths of a package's `passthru.tests`, if it has any.
def test-attributes [attribute: string]: nothing -> list<string> {
    let names = ^nix eval --json --file . $"($attribute).tests" --apply builtins.attrNames | complete
    if $names.exit_code != 0 { return [] }
    $names.stdout | from json | each {|name| $"($attribute).tests.($name)" }
}

# A package's companion inputs, named `<package>-*`, such as celld's rusty_v8 archive. Their fresh-cmds read the
# package's pinned source, so they follow it to whatever release or branch head it holds.
def companions [package: string]: nothing -> list<string> {
    open $"($root)/nix/tamal/lock.json" | get i | columns | where $it starts-with $"($package)-"
}

def refresh-companions [package: string]: nothing -> nothing {
    let inputs = companions $package
    if ($inputs | is-not-empty) {
        load-shell
        ^nixtamal refresh --no-tui ...$inputs
    }
}

# Packages whose input on `main` follows upstream releases.
def release-packages []: nothing -> list<string> {
    lock-packages | where {|package| (pinned $package).kd.0 == $archive_kind }
}

def has-bookmark [name: string]: nothing -> bool {
    (^jj bookmark list $name --template 'name' | str trim) != ""
}

def commit-of [revision: string]: nothing -> string {
    ^jj log --no-graph --revisions $revision --template commit_id | str trim
}

# The working copy must be an empty change on top of `main`.
def assert-on-main []: nothing -> nothing {
    if (^jj diff --summary | str trim) != "" {
        error make {msg: "the working copy has changes; commit or discard them first"}
    }
    if (^jj log --no-graph --revisions "@- & main" --template '"x"' | str trim) != "x" {
        error make {msg: "the working copy is not on top of main"}
    }
}

# nixtamal writes its lock with one input per line; keep that layout so diffs stay one line per input.
def tamal-layout []: record -> string {
    let lock = $in
    let entries = $lock.i | transpose name value | each {|entry| $"($entry.name | to json):($entry.value | to json --raw)" } | str join "\n,"
    $"{\"v\":($lock.v | to json)\n,\"i\":{\n($entries)\n}\n,\"p\":($lock.p | to json --raw)\n}"
}

# Input `name`'s block in a manifest's text.
def input-block [name: string]: string -> list<string> {
    let lines = $in | lines
    let start = $lines | enumerate | where item == $"\t($name) {" | get --optional 0.index
    if $start == null { error make {msg: $"the manifest has no input ($name)"} }
    let end = $lines | enumerate | skip ($start + 1) | where item == "\t}" | get 0.index
    $lines | skip $start | first ($end - $start + 1)
}

# Replace input `name`'s block in the working copy's manifest.
def replace-block [name: string, block: list<string>]: nothing -> nothing {
    let file = $"($root)/nix/tamal/manifest.kdl"
    let lines = open --raw $file | lines
    let start = $lines | enumerate | where item == $"\t($name) {" | get 0.index
    let end = $lines | enumerate | skip ($start + 1) | where item == "\t}" | get 0.index
    ($lines | first $start) ++ $block ++ ($lines | skip ($end + 1)) | str join "\n" | $in + "\n" | save --force $file
}

# Set input `name`'s lock entry in the working copy, then let nixtamal regenerate its loader.
def set-lock-entry [name: string, entry: record]: nothing -> nothing {
    let file = $"($root)/nix/tamal/lock.json"
    open $file | upsert i {|lock| $lock.i | upsert $name $entry } | tamal-layout | save --force --raw $file
    load-shell
    ^nixtamal lock --no-tui
}

# Where a release package's upstream lives, from its archive URL on `main`, and its default branch.
def upstream [package: string]: nothing -> record {
    let url = (pinned $package).kd.1.ur
    let repository = $url | parse --regex '^(?<repository>https://github\.com/[^/]+/[^/]+)/archive/' | get --optional 0.repository
    if $repository == null {
        error make {msg: $"($package): only GitHub release archives can follow a branch, not ($url)"}
    }
    let branch = ^git ls-remote --symref $"($repository).git" HEAD
    | parse --regex 'ref: refs/heads/(?<branch>\S+)\s+HEAD' | get 0.branch
    {repository: $repository, branch: $branch}
}

# Copy a package's state at `revision` into the working copy: its `pkgs/<package>/`, its manifest block and its
# lock entry. Structural, so neighbouring inputs in the lock or manifest never conflict.
def transplant [package: string, revision: string]: nothing -> nothing {
    let directory = $"pkgs/($package)"
    rm --recursive --force $directory
    for file in (^jj file list --revision $revision $directory | lines) {
        mkdir ($file | path dirname)
        ^jj file show --revision $revision $file | save --force --raw $file
    }
    replace-block $package (^jj file show --revision $revision nix/tamal/manifest.kdl | input-block $package)
    set-lock-entry $package (^jj file show --revision $revision nix/tamal/lock.json | from json | get i | get $package)
}

def nightly-message [package: string, merged: bool]: nothing -> string {
    let git = (pinned $package).kd.1
    let title = $"($package): nightly ($git.lr | str substring 0..11) from ($git.rf.1), ($git.dt | str substring 0..9)"
    if $merged { $"($title)\n\nMerges main at (commit-of main | str substring 0..11)." } else { $title }
}

# The head of `branch` in a Git repository.
def branch-head [repository: string, branch: string]: nothing -> string {
    ^git ls-remote --exit-code $repository $"refs/heads/($branch)" | split row "\t" | first
}

# Add a commit to each `<package>/nightly` when upstream's default branch moved: the pin moves to its head, with
# whatever `check --fix` repairs. If `main` moved since the branch's last commit, that commit also merges `main`,
# its tree being `main` plus the package's directory, manifest block and lock entry, so the lock never conflicts.
# The first nightly cuts the branch from `main`. An unmoved upstream adds no commit; the branch only ever grows, so
# any nightly commit stays fetchable. Local only: pushing the branch and opening its pull request are separate.
@example "Advance every nightly" { toolkit nightly }
@example "Advance engram's nightly" { toolkit nightly engram }
export def nightly [
  ...packages: string # Packages following releases on main; all of them when omitted
]: nothing -> nothing {
    cd $root
    assert-on-main
    let packages = if ($packages | is-empty) { release-packages } else { $packages }
    for package in $packages {
        let branch = $"($package)/nightly"
        let source = upstream $package
        let head = branch-head $"($source.repository).git" $source.branch
        if (has-bookmark $branch) {
            let locked = ^jj file show --revision $branch nix/tamal/lock.json | from json | get i | get $package | get kd | get 1
            if ($locked.lr? == $head) {
                print $"($branch): upstream ($source.branch) still at ($head | str substring 0..11)"
                continue
            }
            let merged = (^jj log --no-graph --revisions $"main & ::($branch)" --template '"x"' | str trim) == ""
            if $merged {
                ^jj new $branch main
                ^jj restore --from main
                transplant $package $branch
            } else {
                ^jj new $branch
            }
            load-shell
            ^nixtamal refresh --no-tui $package
            refresh-companions $package
            if $package in (plugin-names) { cargo-lock $package }
            check --fix $package
            ^jj describe --message (nightly-message $package $merged)
        } else {
            ^jj new main
            replace-block $package [
                $"\t($package) {"
                "\t\tgit fetch-time=eval {"
                $"\t\t\trepository \"($source.repository).git\""
                $"\t\t\tbranch ($source.branch)"
                "\t\t}"
                "\t}"
            ]
            load-shell
            ^nixtamal lock --force --no-tui $package
            refresh-companions $package
            if $package in (plugin-names) { cargo-lock $package }
            check --fix $package
            ^jj describe --message (nightly-message $package false)
        }
        ^jj bookmark set $branch --revision @
        print $"($branch): (^jj log --no-graph --revisions @ --template 'description.first_line()')"
        ^jj new main
    }
}

# Release each package whose upstream tagged a newer release: the last nightly lands on `main` as one curated
# commit, its input back on the release archive at the new tag, built, tested and repaired; `main` moves there and
# is tagged `<package>/stable` and `<package>/releases/<tag>`. The nightly branch is left alone: its next commit
# merges `main`. A package already at its newest release is checked and tagged `<package>/stable` again.
# Local only: pushing is a separate step.
@example "Release every package with a new upstream tag" { toolkit release }
@example "Release engram" { toolkit release engram }
export def release [
  ...packages: string # Packages following releases on main, or Nushell plugins; every release package when omitted
]: nothing -> nothing {
    cd $root
    assert-on-main
    let packages = if ($packages | is-empty) { release-packages } else { $packages }
    for package in $packages {
        if $package in (plugin-names) {
            check $package
            tag-plugin $package
            continue
        }
        let current = pinned $package
        let source = upstream $package
        let newest = ^nu --no-config-file nix/fresh.nu release $source.repository | str trim
        if $newest == $current.fv {
            check $package
        } else {
            land $package $current $source.repository
        }
        let commit = commit-of main
        ^git tag --force $"($package)/stable" $commit
        let tag = $"($package)/releases/((pinned $package).fv)"
        if (^git tag --list $tag | str trim) == "" { ^git tag $tag $commit }
        print $"($package): ((pinned $package).fv) stable at ($commit | str substring 0..11)"
    }
}

# A release's commit message: title, upstream release URL and notes (capped), and trailers naming the nightly
# it squashes.
def release-message [package: string, repository: string, tag: string, nightly: any]: nothing -> string {
    let path = $repository | url parse | get path | str trim --char '/'
    let notes = try {
        http get --headers [Accept application/vnd.github+json] $"https://api.github.com/repos/($path)/releases/tags/($tag)"
    } catch { null }
    let url = $notes.html_url? | default $"($repository)/releases/tag/($tag)"
    let body = $notes.body? | default "" | str replace --all "\r" "" | str trim | lines
    let shown = if ($body | length) > 40 { ($body | first 40) ++ ["", $"Full notes: ($url)"] } else { $body }
    let trailers = if $nightly == null { [] } else {
        [$"Squashed-From: ($package)/nightly@($nightly)" $"Pull-Request: ($package)/nightly"]
    }
    [$"($package): ($tag | str replace --regex '^v' '')" "" $url]
    | append (if ($shown | is-empty) { [] } else { [""] ++ $shown })
    | append (if ($trailers | is-empty) { [] } else { [""] ++ $trailers })
    | str join "\n"
}

# Land `<package>/nightly` on `main` as one commit with the input back on its release archive, relocked at the
# newest tag and checked, then move `main` there.
def land [package: string, current: record, repository: string]: nothing -> nothing {
    let branch = $"($package)/nightly"
    let archive = open --raw $"($root)/nix/tamal/manifest.kdl" | input-block $package
    let nightly = if (has-bookmark $branch) { commit-of $branch } else { null }
    ^jj new main
    if $nightly != null { transplant $package $branch }
    replace-block $package $archive
    set-lock-entry $package $current
    load-shell
    ^nixtamal lock --force --no-tui $package
    refresh-companions $package
    if $package in (plugin-names) { cargo-lock $package }
    check --fix $package
    ^jj describe --message (release-message $package $repository (pinned $package).fv $nightly)
    ^jj bookmark set main --revision @
    ^jj new main
}

# Regenerate each Nushell plugin's `Cargo.lock` for its pinned source and the Nushell its build targets.
@example "Regenerate nu_plugin_ws's lock" { toolkit cargo-lock nu-plugin-ws }
export def cargo-lock [
  ...plugins: string # Plugin packages under pkgs/; all of them when omitted
]: nothing -> nothing {
    cd $root
    let plugins = if ($plugins | is-empty) { plugin-names } else { $plugins }
    for plugin in $plugins {
        let source = ^nix build --no-link --print-out-paths --file . $"($plugin).src" | str trim
        let work = mktemp --directory --tmpdir cargo-lock.XXXXXX
        try {
            ^cp --recursive --no-preserve=mode $"($source)/." $work
            ^nix shell --impure --expr "(import (import ./nix/tamal {}).nixpkgs {}).cargo" --command cargo update --workspace --manifest-path ($work | path join Cargo.toml)
            cp --force ($work | path join Cargo.lock) $"pkgs/($plugin)/Cargo.lock"
        } catch {|err|
            rm --recursive --force $work
            error make {msg: $"($plugin): ($err.msg)"}
        }
        rm --recursive --force $work
    }
}
