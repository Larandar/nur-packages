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

use nix/tangled.nu

# Make a CI checkout able to plan, verify and publish: full history, branches and tags from `origin`, a colocated jj
# repository tracking them, and a CI identity. With the `NUR_SSH_KEY` secret, also install the key and push to
# `NUR_PUSH_URL`.
export def ci-prepare []: nothing -> nothing {
    cd $root
    let shallow = (^git rev-parse --is-shallow-repository | str trim) == "true"
    ^git fetch --tags ...(if $shallow { [--unshallow] } else { [] }) origin "+refs/heads/*:refs/remotes/origin/*"
    if not ($"($root)/.jj" | path exists) { ^jj git init --colocate }
    ^jj config set --repo user.name ($env.NUR_CI_NAME? | default "nur-packages CI")
    ^jj config set --repo user.email ($env.NUR_CI_EMAIL? | default "ci@nur-packages.invalid")
    ^jj bookmark track "*" --remote origin
    if (publishable) {
        let key = $"($env.HOME)/.ssh/nur-packages"
        mkdir ($key | path dirname)
        $"($env.NUR_SSH_KEY | str trim)\n" | save --force $key
        ^chmod 600 $key
        ^git config core.sshCommand $"ssh -i ($key) -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
        ^git remote set-url --push origin $env.NUR_PUSH_URL
    }
    ^jj new main
}

# Publishing needs the `NUR_SSH_KEY` secret; without it, `--publish` runs stay local.
def publishable []: nothing -> bool {
    ($env.NUR_SSH_KEY? | default "" | str trim) != ""
}

def publishing [requested: bool]: nothing -> bool {
    if $requested and not (publishable) { print "NUR_SSH_KEY is not set: building locally, publishing nothing." }
    $requested and (publishable)
}

# The work the pins call for, found without building: `release` (a release package's upstream tagged a newer
# release), `nightly` (its default branch moved past the nightly branch) and `update` (an input `main` owns is
# stale: nixpkgs, tooling, packages without releases such as the Nushell plugins).
@example "List every job" { toolkit jobs }
@example "List engram's jobs" { toolkit jobs engram }
export def jobs [
  ...names: string # Packages or inputs to consider; all of them when omitted
  --kind: string # Only `release`, `nightly` or `update` jobs
]: nothing -> table {
    cd $root
    load-shell
    let stale = ^nixtamal list-stale --color never | lines | where $it != "" | parse '{name}: {fresh}'
    let released = release-packages
    let owned = owned-inputs
    let releases = $stale | where name in $released | each {|row| {kind: release, name: $row.name, to: $row.fresh} }
    let updates = $stale | where name in $owned | each {|row| {kind: update, name: $row.name, to: $row.fresh} }
    let nightlies = $released | each {|package|
        let source = upstream $package
        let head = branch-head $"($source.repository).git" $source.branch
        if (nightly-rev $package) != $head { {kind: nightly, name: $package, to: $head} }
    } | compact
    $releases ++ $nightlies ++ $updates
    | where {|job| ($names | is-empty) or $job.name in $names }
    | where {|job| $kind == null or $job.kind == $kind }
}

# Inputs `main` owns: everything but release packages and their companions.
def owned-inputs []: nothing -> list<string> {
    let released = release-packages | each {|package| [$package] ++ (companions $package) } | flatten
    open $"($root)/nix/tamal/lock.json" | get i | columns | where $it not-in $released
}

# The upstream revision `<package>/nightly` pins, or null without a nightly branch.
def nightly-rev [package: string]: nothing -> any {
    let branch = $"($package)/nightly"
    if not (has-bookmark $branch) { return null }
    ^jj file show --revision $branch nix/tamal/lock.json | from json | get i | get $package | get kd | get 1 | get lr?
}

def candidate-branch [job: record]: nothing -> string {
    $"ci/($job.kind)/($job.name)"
}

# Prepare a candidate for each job on `ci/<kind>/<name>`: the pin move, built on what it changes (the nightly branch,
# or `main`), with nothing built yet; `toolkit verify` builds, repairs and advances it. With `--publish`, push the
# candidates (their pushes start CI's verify runs) and open or update the release and update pull requests.
@example "Prepare every job locally" { toolkit plan }
@example "CI's scheduled planner" { toolkit plan --publish }
export def plan [
  ...names: string # Packages or inputs to consider; all of them when omitted
  --kind: string # Only `release`, `nightly` or `update` jobs
  --publish # Push the candidates and open their pull requests
]: nothing -> list<string> {
    cd $root
    assert-on-main
    let publish = publishing $publish
    let found = jobs ...$names --kind $kind
    print ($found | table)
    $found | each {|job|
        let prepared = match $job.kind {
            nightly => (prepare-nightly $job.name)
            release => (prepare-release $job.name)
            update => (prepare-update $job.name)
        }
        let candidate = candidate-branch $job
        if $prepared {
            ^jj bookmark set $candidate --revision @ --allow-backwards
            if $publish {
                ^git push --force origin $"refs/heads/($candidate):refs/heads/($candidate)"
                if $job.kind != nightly {
                    let message = ^jj log --no-graph --revisions $candidate --template description | str trim
                    tangled open-or-update (tangled session) $env.NUR_REPO_DID $candidate main ($message | lines | first) $message | ignore
                }
            }
        }
        ^jj new main
        if $prepared { $candidate }
    } | compact
}

# A nightly candidate: one commit on `<package>/nightly` moving the pin to upstream's default branch head. When `main`
# moved since the branch's last commit, the commit merges it: its tree is `main` plus the package's directory,
# manifest block and lock entry, so the lock never conflicts. The first nightly cuts the branch from `main`.
def prepare-nightly [package: string]: nothing -> bool {
    let branch = $"($package)/nightly"
    let source = upstream $package
    let merged = (has-bookmark $branch) and ((^jj log --no-graph --revisions $"main & ::($branch)" --template '"x"' | str trim) == "")
    if (has-bookmark $branch) {
        if $merged {
            ^jj new $branch main
            ^jj restore --from main
            transplant $package $branch
        } else {
            ^jj new $branch
        }
        load-shell
        ^nixtamal refresh --no-tui $package
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
    }
    refresh-companions $package
    ^jj describe --message (nightly-message $package $merged)
    true
}

# A release candidate: one commit on `main` carrying the nightly's state with the input back on the release archive
# at the newest tag, described with the upstream release notes.
def prepare-release [package: string]: nothing -> bool {
    let branch = $"($package)/nightly"
    let current = pinned $package
    let repository = (upstream $package).repository
    let archive = open --raw $"($root)/nix/tamal/manifest.kdl" | input-block $package
    let nightly = if (has-bookmark $branch) { commit-of $branch } else { null }
    ^jj new main
    if $nightly != null { transplant $package $branch }
    replace-block $package $archive
    set-lock-entry $package $current
    load-shell
    ^nixtamal lock --force --no-tui $package
    refresh-companions $package
    ^jj describe --message (release-message $package $repository (pinned $package).fv $nightly)
    true
}

# An update candidate: one commit on `main` refreshing input `name`; false when only its recorded fresh value moved.
def prepare-update [name: string]: nothing -> bool {
    let before = pinned $name | reject --optional fv
    ^jj new main
    load-shell
    ^nixtamal refresh --no-tui $name
    if ((pinned $name | reject --optional fv) == $before) {
        ^jj abandon @
        return false
    }
    ^jj describe --message $"Update ($name)"
    true
}

# Build, test and repair each candidate (`check --fix`, Nushell plugin locks), folding repairs into it. A green nightly
# candidate advances `<package>/nightly`; a green release or update lands on `main` as one commit and is tagged.
# With `--publish`, push what moved, keep the pull requests current, and settle the landed ones as merged.
@example "Verify every local candidate" { toolkit verify }
@example "CI's run for one pushed candidate" { toolkit verify --publish ci/release/engram }
export def verify [
  ...candidates: string # Candidate branches `ci/<kind>/<name>`; every local one when omitted
  --publish # Push the results and update pull requests
]: nothing -> nothing {
    cd $root
    assert-on-main
    let publish = publishing $publish
    let candidates = if ($candidates | is-empty) {
        ^jj bookmark list --template 'name ++ "\n"' | lines | where $it starts-with "ci/" | uniq
    } else { $candidates }
    for candidate in $candidates {
        let job = $candidate | parse 'ci/{kind}/{name}' | first
        ^jj new $candidate
        let packages = affected $job
        let plugins = $packages | where $it in (plugin-names)
        if ($plugins | is-not-empty) { cargo-lock ...$plugins }
        if ($packages | is-not-empty) { check --fix ...$packages }
        ^jj squash
        if $job.kind == nightly {
            advance-nightly $job.name $candidate $publish
        } else {
            land $job $candidate $publish
        }
        ^jj bookmark delete $candidate
        if $publish { ^git push origin $":refs/heads/($candidate)" }
        ^jj new main
    }
}

# The packages a job's candidate must build: the package itself, or for an update the package its input feeds, and
# every package when nixpkgs moves.
def affected [job: record]: nothing -> list<string> {
    if $job.kind != update { return [$job.name] }
    # The repository tooling (`default.devShell`) runs the patched nixtamal on nixpkgs.
    if $job.name == nixpkgs { return ((lock-packages) ++ [nixtamal default]) }
    if $job.name == nixtamal { return [nixtamal default] }
    let attributes = ^nix eval --json --impure --expr "builtins.attrNames (import ./. {})" | from json
    if $job.name in $attributes { [$job.name] } else { [] }
}

def advance-nightly [package: string, candidate: string, publish: bool]: nothing -> nothing {
    let branch = $"($package)/nightly"
    ^jj bookmark set $branch --revision $candidate
    print $"($branch): (^jj log --no-graph --revisions $branch --template 'description.first_line()')"
    if $publish {
        ^git push origin $"refs/heads/($branch):refs/heads/($branch)"
        tangled open-or-update (tangled session) $env.NUR_REPO_DID $branch main $"($package): nightly" "Upstream's default branch, built, tested and repaired; it lands with the next release." | ignore
    }
}

# Copy into the working copy what `revision` changed since `base`: changed files under pkgs/, and the lock entries and
# manifest blocks of changed inputs, then regenerate the loader. Structural, so neighbouring inputs never conflict.
def apply-changes [revision: string, base: string]: nothing -> nothing {
    let pins = [nix/tamal/manifest.kdl nix/tamal/lock.json nix/tamal/default.nix]
    for path in (^jj diff --from $base --to $revision --name-only | lines | where $it not-in $pins) {
        if (^jj file list --revision $revision $path | str trim) == "" {
            rm --force $path
        } else {
            mkdir ($path | path dirname)
            ^jj file show --revision $revision $path | save --force --raw $path
        }
    }
    let before = ^jj file show --revision $base nix/tamal/lock.json | from json | get i
    let after = ^jj file show --revision $revision nix/tamal/lock.json | from json | get i
    let manifest = ^jj file show --revision $revision nix/tamal/manifest.kdl
    for input in ($after | columns | where {|input| ($before | get --optional $input) != ($after | get $input) }) {
        replace-block $input ($manifest | input-block $input)
        let file = $"($root)/nix/tamal/lock.json"
        open $file | upsert i {|lock| $lock.i | upsert $input ($after | get $input) } | tamal-layout | save --force --raw $file
    }
    load-shell
    ^nixtamal lock --no-tui
}

# Land a verified release or update candidate on the latest `main` as one commit, then tag it.
def land [job: record, candidate: string, publish: bool]: nothing -> nothing {
    let message = ^jj log --no-graph --revisions $candidate --template description | str trim
    mut attempts = 0
    loop {
        let base = commit-of $"fork_point\(main | ($candidate)\)"
        ^jj new main
        apply-changes $candidate $base
        ^jj describe --message $message
        ^jj bookmark set main --revision @
        if not $publish { break }
        let pushed = ^git push origin "refs/heads/main:refs/heads/main" | complete
        if $pushed.exit_code == 0 { break }
        # Another candidate landed first: land again on top of it.
        $attempts += 1
        if $attempts >= 3 { error make {msg: $"($candidate): main kept moving; ($pushed.stderr | str trim)"} }
        ^jj abandon @
        ^git fetch origin main
        ^jj bookmark set main --revision "main@origin" --allow-backwards
    }
    let tags = match $job.kind {
        release => {
            let commit = commit-of main
            ^git tag --force $"($job.name)/stable" $commit
            let tag = $"($job.name)/releases/((pinned $job.name).fv)"
            if (^git tag --list $tag | str trim) == "" { ^git tag $tag $commit }
            [$"($job.name)/stable" $tag]
        }
        update => {
            affected $job | where $it in (plugin-names) | each {|plugin| tag-plugin $plugin } | flatten
        }
    }
    print $"main: ($message | lines | first)"
    if $publish {
        for tag in $tags { ^git push --force origin $"refs/tags/($tag)" }
        let session = tangled session
        tangled settle $session $env.NUR_REPO_DID $candidate
        if $job.kind == release { tangled settle $session $env.NUR_REPO_DID $"($job.name)/nightly" }
    }
}

# Tag `main` for a Nushell plugin that builds there: `<plugin>/stable`, and `<plugin>/releases/<version>`, which
# moves with each newer commit that still compiles as that `<crate version>-nu-<nushell version>`.
def tag-plugin [plugin: string]: nothing -> list<string> {
    let commit = commit-of main
    let version = ^nix eval --raw --file . $"($plugin).version" | str trim
    ^git tag --force $"($plugin)/stable" $commit
    ^git tag --force $"($plugin)/releases/($version)" $commit
    print $"($plugin): ($version) stable at ($commit | str substring 0..11)"
    [$"($plugin)/stable" $"($plugin)/releases/($version)"]
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
    # A package without derived hashes, such as nixtamal, has no lock.nuon.
    let entry = if ($file | path exists) { open $file } else { {} }
    # An attribute that is not itself an input, such as `default`, has no tag to check.
    let input = open $"($root)/nix/tamal/lock.json" | get i | get --optional $package
    if $input != null and $input.kd.0 == $archive_kind {
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

# Advance each nightly branch whose upstream moved: `plan` then `verify` for their nightly jobs, locally.
@example "Advance every nightly" { toolkit nightly }
export def nightly [...packages: string]: nothing -> nothing {
    let candidates = plan ...$packages --kind nightly
    if ($candidates | is-not-empty) { verify ...$candidates }
}

# Land every new upstream release, locally: `plan` then `verify` for their release jobs. A package already at its
# newest release, or a Nushell plugin, is checked and its stable tag moved instead.
@example "Release every package with a new upstream tag" { toolkit release }
export def release [...packages: string]: nothing -> nothing {
    let candidates = plan ...$packages --kind release
    if ($candidates | is-not-empty) { verify ...$candidates }
    let landed = $candidates | each { str replace "ci/release/" "" }
    let requested = if ($packages | is-empty) { release-packages } else { $packages }
    for package in ($requested | where $it not-in $landed) {
        check $package
        if $package in (plugin-names) {
            tag-plugin $package | ignore
        } else {
            let commit = commit-of main
            ^git tag --force $"($package)/stable" $commit
            let tag = $"($package)/releases/((pinned $package).fv)"
            if (^git tag --list $tag | str trim) == "" { ^git tag $tag $commit }
            print $"($package): ((pinned $package).fv) stable at ($commit | str substring 0..11)"
        }
    }
}

# Refresh the inputs `main` owns, locally: `plan` then `verify` for their update jobs. Each lands on its own; one whose
# new pin does not build stays unlanded, so `main` keeps its last good pin.
@example "Refresh every input main owns" { toolkit update }
export def update [...inputs: string]: nothing -> nothing {
    let candidates = plan ...$inputs --kind update
    for candidate in $candidates {
        try { verify $candidate } catch {|err| print $"($candidate): not landed: ($err.msg | lines | first)" }
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
