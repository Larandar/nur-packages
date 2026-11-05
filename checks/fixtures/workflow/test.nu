use std/assert
overlay use --prefix toolkit.nu
use nix/github.nu

def commit [revision: string]: nothing -> string {
    ^jj log --no-graph -r $revision -T commit_id | str trim
}

def candidate [] {
    ^jj new main
    "candidate" | save --force candidate.txt
    ^jj describe -m "Update home-manager"
    ^jj bookmark set ci/update/home-manager -r @ --allow-backwards
    ^jj new main
}

def log [] {
    open --raw $env.TEST_LOG | lines
}

def --env reset-log [] {
    "" | save --force $env.TEST_LOG
}

$env.TEST_LOG = $env.HOME | path join checks.log
$env.TEST_SOURCE = $env.HOME | path join source
mkdir ($env.TEST_SOURCE | path join searchwala-calf)
"lock" | save ($env.TEST_SOURCE | path join searchwala-calf Cargo.lock)
mkdir nix/tamal pkgs/waterfox pkgs/searchwala-calf/crate
{v: 1, i: {searchwala-calf: {kd: [1 {}], fv: "v1"}}, p: {}} | to json | save nix/tamal/lock.json
"inputs {\n\tsearchwala-calf {\n\t}\n}\n" | save nix/tamal/manifest.kdl
"{}" | save pkgs/waterfox/lock.nix
'{ tag = "v1"; }' | save pkgs/searchwala-calf/lock.nix
"lock" | save pkgs/searchwala-calf/crate/Cargo.lock
^git init --initial-branch=main
^git -c user.name=test -c user.email=test@example.invalid add .
^git -c user.name=test -c user.email=test@example.invalid commit -m initial
^jj git init --colocate
^jj config set --repo user.name '"test"'
^jj config set --repo user.email '"test@example.invalid"'
^jj new main
let initial = commit main

# Home Manager validates Waterfox twice: on the candidate and on the landing tree.
candidate
reset-log
toolkit verify ci/update/home-manager
assert equal (log | where $it == waterfox | length) 2
assert equal (log | where $it == waterfox.tests.module | length) 2

# Packages without passthru.tests still validate their builds normally.
candidate
$env.TEST_NO_TESTS = true
reset-log
toolkit verify ci/update/home-manager
assert equal (log | where $it == waterfox | length) 2
assert equal (log | where $it == waterfox.tests.module | length) 0
$env.TEST_NO_TESTS = false

# nix-darwin also validates SearchWala, regenerating its Cargo lock in both trees.
^jj new main
"darwin" | save --force candidate.txt
^jj describe -m "Update nix-darwin"
^jj bookmark set ci/update/nix-darwin -r @
^jj new main
reset-log
toolkit verify ci/update/nix-darwin
for target in [waterfox waterfox.tests.module searchwala-calf searchwala-calf.tests.module cargo] {
    assert equal (log | where $it == $target | length) 2
}

# A release must repair its stale tag before building the source to regenerate Cargo.lock.
^jj new main
{v: 1, i: {searchwala-calf: {kd: [1 {}], fv: "v2"}}, p: {}} | to json | save --force nix/tamal/lock.json
^jj describe -m "searchwala-calf: 2"
^jj bookmark set ci/release/searchwala-calf -r @
^jj new main
reset-log
toolkit verify ci/release/searchwala-calf
for target in [source cargo searchwala-calf searchwala-calf.tests.module] {
    assert equal (log | where $it == $target | length) 2
}
assert (open --raw pkgs/searchwala-calf/lock.nix | str contains 'tag = "v2"')
assert equal (^git rev-parse searchwala-calf/releases/v2 | str trim) (commit main)

# Old nightly directories must migrate their JSON hashes before evaluation and hash repair.
^jj new main
open nix/tamal/lock.json | upsert i.kasetto {kd: [1 {}], fv: "v2"} | to json | save --force nix/tamal/lock.json
open --raw nix/tamal/manifest.kdl
| str replace "\n}" "\n\tkasetto {\n\t}\n}"
| save --force nix/tamal/manifest.kdl
^jj describe -m "Release inputs"
^jj bookmark set main -r @
^jj new main
for package in [engram kasetto] {
    ^jj new main
    mkdir $"pkgs/($package)"
    '{ lib, ... }: { hash = (lib.importJSON ./lock.nuon).cargoHash; }' | save $"pkgs/($package)/default.nix"
    {tag: "v1", cargoHash: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}
    | to json | save $"pkgs/($package)/lock.nuon"
    if $package == engram {
        '{ tag = "v2"; }' | save $"pkgs/($package)/lock.nix"
    }
    ^jj describe -m $"($package): nightly"
    let kind = if $package == engram { "nightly" } else { "release" }
    ^jj bookmark set $"ci/($kind)/($package)" -r @
    ^jj new main
    reset-log
    toolkit verify $"ci/($kind)/($package)"
    assert equal (log | where $it == $package | length) (if $kind == nightly { 1 } else { 2 })
    let branch = if $kind == nightly { $"($package)/nightly" } else { "main" }
    let lock = ^jj file show -r $branch $"pkgs/($package)/lock.nix"
    assert ($lock | str contains 'cargoHash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="')
    assert ($lock | str contains 'tag = "v2"')
    let expression = ^jj file show -r $branch $"pkgs/($package)/default.nix"
    assert ($expression | str contains '(import ./lock.nix)')
    assert equal (^jj file list -r $branch $"pkgs/($package)/lock.nuon" | str trim) ""
}

# A candidate based on older main must not land when the combined tree fails.
candidate
^jj new main
"concurrent" | save concurrent.txt
^jj describe -m concurrent
^jj bookmark set main -r @
let newer = commit main
^jj new main
$env.TEST_FAIL = true
reset-log
let failed = ^nu --no-config-file -c 'overlay use --prefix toolkit.nu; toolkit verify ci/update/home-manager' | complete
assert ($failed.exit_code != 0)
assert ($failed.stderr | str contains "root cause: combined tree failed")
assert equal (commit main) $newer
assert equal (^jj bookmark list ci/update/home-manager -T name | str trim) ci/update/home-manager
assert equal (log | where $it == waterfox | length) 2
assert equal (log | where $it == push | length) 0

# Module evaluation failure during discovery must also block the combined landing.
$env.TEST_FAIL = false
$env.TEST_DISCOVERY_FAIL = true
reset-log
assert (try { toolkit verify ci/update/home-manager; false } catch { true })
assert equal (commit main) $newer
assert equal (log | where $it == waterfox | length) 2
assert equal (log | where $it == push | length) 0

# A discovery failure on the candidate itself must fail before any landing.
^jj new main
"discovery" | save --force candidate.txt
^jj describe -m "Update home-manager"
^jj bookmark set ci/update/home-manager -r @ --allow-backwards
^jj new main
reset-log
assert (try { toolkit verify ci/update/home-manager; false } catch { true })
assert equal (commit main) $newer
assert equal (log | where $it == waterfox | length) 1
$env.TEST_DISCOVERY_FAIL = false

# Simulate a rejected push and fetch of a newer main, without any network writes.
$env.TEST_FAIL = false
^jj bookmark set main -r $initial --allow-backwards
^jj new main
candidate
$env.TEST_REMOTE = $newer
$env.GH_TOKEN = "test-placeholder"
$env.TEST_PR = "success"
reset-log
toolkit verify --publish ci/update/home-manager
assert ("concurrent.txt" | path exists)
assert equal (log | where $it == waterfox | length) 3
assert equal (log | where $it == push | length) 3

# If the retry's combined tree fails, keep fetched main and the candidate.
^jj bookmark set main -r $initial --allow-backwards
^jj new main
candidate
$env.TEST_FAIL = true
reset-log
assert (try { toolkit verify --publish ci/update/home-manager; false } catch { true })
assert equal (commit main) $newer
assert equal (log | where $it == waterfox | length) 3
assert equal (log | where $it == push | length) 1
assert equal (^jj bookmark list ci/update/home-manager -T name | str trim) ci/update/home-manager

# A push rejected without main moving must stop immediately and restore main.
$env.TEST_FAIL = false
$env.TEST_REMOTE = $initial
^jj bookmark set main -r $initial --allow-backwards
^jj new main
candidate
reset-log
assert (try { toolkit verify --publish ci/update/home-manager; false } catch { true })
assert equal (commit main) $initial
assert equal (log | where $it == push | length) 1
assert equal (^jj bookmark list ci/update/home-manager -T name | str trim) ci/update/home-manager

# Policy denial is nonfatal, but unrelated API failures still fail publishing.
$env.TEST_PR = "policy"
assert equal (github open-or-update branch main title body) ""
$env.TEST_PR = "denied"
assert (try { github open-or-update branch main title body; false } catch { true })
$env.TEST_PR = "success"
assert equal (github open-or-update branch main title body) "https://github.com/example/test/pull/1"
print "workflow: all cases passed"
