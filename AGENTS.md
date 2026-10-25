# Agent rules

## Pins

Every hard pin belongs to nixtamal. A hard pin is anything that fixes a
revision or hash of an external source: nixpkgs, a package `src`, a patch.

- Declare it as an input in `nix/tamal/manifest.kdl`. Its `fresh-cmd` is the
  script that fetches the desired stability level; the lock records what it
  returned.
- Consume it through `nix/pins.nix`: `default.nix` passes `inputs.<name>` to
  the package as `src`, with a `version` derived from the pin.
- Fetch at evaluation (`fetch-time=eval`) any input whose files evaluation
  reads, such as `Cargo.toml` or `Cargo.lock`, so nothing imports from a
  derivation.
- Never add flake inputs, `fetch*` calls with a literal `rev` or `hash`, or
  `<nixpkgs>` lookups.
- Never edit `nix/tamal/default.nix`, `lock.json`, or `darcs_context/`;
  nixtamal rewrites them.

| Input | Stability level | `fresh-cmd` source |
| --- | --- | --- |
| `nixpkgs` | `nixpkgs-unstable` channel release | `https://channels.nixos.org/nixpkgs-unstable` redirect |
| `nixtamal` | darcs `next` head | `https://darcs.toastal.in.th/nixtamal/next/_darcs/weak_hash` |
| `iets` | newest `X.Y.Z` release tag | `nix/fresh.nu release https://github.com/numtide/iets` |

An input named `<pkg>-*` is a companion of `<pkg>`, such as `celld-rusty-v8`:
its `fresh-cmd` reads the pinned package source (`nix/fresh.nu locked-dep`), so
`toolkit nightly` and `toolkit release` refresh it after moving `<pkg>`, and
`toolkit update` leaves it alone.

`nixpkgs` must stay `fetch-time=eval` with a SHA-256 hash: the loader
bootstraps from it, and `default.nix` imports it during evaluation.

To change a stability level, edit the input's source and `fresh-cmd`, then
refresh. To hold a pin, mark the input `frozen=#true`.

## Channels

One input per package. On `main` it follows upstream's newest `X.Y.Z` tag: an
archive whose `fresh-cmd` is
`nu --no-config-file nix/fresh.nu release <repository>`, versioned as the tag
without `v`. An upstream without releases follows its branch on `main`,
versioned `0-unstable-<date>`. Speed lives in Git refs, not attributes:

| Ref | Kind | Points at |
| --- | --- | --- |
| `<pkg>/nightly` | branch, only ever growing, with an open PR into `main` | the input following upstream's default branch, versioned `<tag>-unstable-<date>` |
| `<pkg>/stable` | moving tag | the latest `main` commit where `toolkit check <pkg>` passed |
| `<pkg>/releases/<tag>` | immutable tag | the `main` commit that landed that release |

- `toolkit nightly` adds a commit to a nightly branch only when upstream's
  branch moved, with whatever repairs `check --fix` made. If `main` moved since
  the branch's last commit, that commit merges `main` (two parents); its tree is
  `main` plus the package's directory, manifest block and lock entry, so the
  one-input-per-line lock never conflicts.
- `toolkit release` lands a new upstream release: the last nightly becomes one
  curated commit on `main` with the input back on the release archive at the
  new tag, the upstream release URL and notes, and `Squashed-From` /
  `Pull-Request` trailers; it is checked, then tagged. The nightly branch is
  not rewritten: its next commit merges `main`.
- Nightly branches are never rewritten, so any nightly commit a consumer locked
  stays fetchable.

These commands work locally; pushing branches and tags and opening the pull
requests are separate, authorized steps.

## Derived hashes

Hashes a build derives from its source (`vendorHash`, `cargoHash`) live in
`pkgs/<pkg>/lock.nix`, with the release `tag` they were computed for;
evaluating `<pkg>` fails while that tag differs from a release pin. Never edit
them by hand: `toolkit check <pkg>` builds the package and its
`passthru.tests` with [iets](https://github.com/numtide/iets) and proposes the
`lock.nix` change a failing hash or stale tag needs; `--fix` rewrites the tag
and lets iets's `fix-hashes` rewrite each mismatching hash in place as it
builds. `toolkit update` runs `check --fix` for every package whose pins moved,
and `toolkit hashes <pkg>` recomputes every hash from scratch. A package can be
a set of binaries, one member per binary crate (`snix.store`,
`snix.nar-bridge`); `check` builds each derivation member, and the members
share one vendored dependency set and its `cargoHash`. `lock.nix` holds one
string literal per key and no hash twice, so iets finds each hash in exactly
one place.

iets comes from numtide's flake, through its `flake-compat`, pinned as the
`iets` input and put on PATH by `default.devShell`. It evaluates impurely, as
`nix build --file` does, since nixpkgs reads `currentSystem`.

## Nushell plugins

`pkgs/nu-plugin-<name>/` builds a plugin with the shared
`pkgs/nushell-plugins/builder.nix` against `pkgs.nushell`, the shell it loads
in: `apply.nu` pins its `nu-*` dependencies to exactly that release and applies
the ast-grep rules under its `rules/`, one per source change a Nushell release
forces; a rule that matches nothing fails the build, so stale rules get deleted.
Its `Cargo.lock` is generated: `toolkit cargo-lock` rewrites it whenever its pin
or nixpkgs moves.

Plugins follow upstream's default branch on `main`, with no nightly: `main`
holds the latest commit that compiles for the current Nushell. Their version is
`<crate version>-nu-<nushell version>`, and the tag
`<plugin>/releases/<version>` moves to each newer commit that still compiles as
that version, so it ends on the last one that did. `toolkit update` advances
them, keeping `main`'s pin when upstream's head does not build.

## Own crates

A package with a crate of its own over its pin keeps it in `pkgs/<pkg>/crate/`,
assembled at `<pkg>/` in its build tree (`.src`) beside the pinned source, such
as `searchwala-calf` over SearchWala. Its `Cargo.lock` is generated against the
pinned release: `toolkit cargo-lock <pkg>` rewrites it, and `toolkit verify`
does so whenever the pin moves, as for the Nushell plugins.

## Package patches

Optional patches live in `pkgs/<package>/patches/` and are opt-in through the
package's `enabledPatches` argument; evaluating the package without them prints
the ones available. `nixtamal`'s `shell` patch (`fresh-cmd shell="nu"`) comes
from midgard-flakes, rebased onto the pinned `next`. When a refresh moves
`next`, rebuild with the patch and rebase it if it no longer applies.

`nixtamal`'s `packages` argument puts tools first on the runner's PATH, ahead
of its prefetchers and the caller's PATH, such as `[nushell]`.
`default.devShell` enables the `shell` patch with `packages = [nushell]`.

## CI

Spindle runs `.tangled/workflows/`, building through the host's Nix daemon
(`NIX_REMOTE=daemon`): outputs land in the host store, which owns caching.

- `plan.yml`, scheduled: `toolkit plan --publish` finds the jobs
  (`toolkit jobs`: new upstream releases, moved nightlies, stale inputs `main`
  owns) and pushes one candidate branch `ci/<kind>/<name>` per job, with
  nothing built. Release and update candidates get a pull request into `main`.
- `verify.yml`, on each candidate push: `toolkit verify --publish` builds,
  tests and repairs the candidate, then advances `<pkg>/nightly` (updating its
  pull request) or lands the release or update on `main`, tags it, and records
  its pull requests as merged. An update whose pin does not build is not
  landed, so `main` keeps its last good pin. The next nightly after a release
  opens a new pull request.
- `check.yml`: `toolkit check` on pull requests from people.

iets keeps its cache on the host through `IETS_CACHE_DIR`: `plan.yml` and
`verify.yml` share `/var/cache/iets/trusted`, and `check.yml` uses
`/var/cache/iets/unknown`, for code of unknown origin. A cache entry answers
an evaluation, so the workflows that hold the publishing secrets never read
one a pull request wrote.

Publishing needs two spindle secrets: `NUR_SSH_KEY`, the private half of a key
registered on the account, for pushes; and `NUR_APP_PASSWORD`, an ATProto app
password, for the pull request records (`nix/tangled.nu`). Without
`NUR_SSH_KEY`, `--publish` runs build and publish nothing.

## Commands

```nu
overlay use --prefix toolkit.nu
toolkit update           # plan + verify the update jobs, one landing each
toolkit update nixpkgs   # refresh one input
toolkit check engram     # build and test, propose lock.nix fixes
toolkit check --fix      # the same for every package, applying the fixes
toolkit hashes engram    # recompute one package's lock.nix from scratch
toolkit jobs             # what the pins call for, without building
toolkit plan             # prepare one candidate per job on ci/<kind>/<name>
toolkit verify           # build, repair, then advance or land each candidate
toolkit nightly          # plan + verify the nightly jobs
toolkit release          # plan + verify the release jobs, tag the rest
toolkit load-shell       # repo tooling (this repo's nixtamal) in scope
toolkit load-shell nixtamal  # plus each named package's devShell
```

A toolkit command that needs a package's dev shell starts with
`load-shell <package>`.

`nix fmt .` formats with alejandra and skips `nix/tamal/`. Resolve conflicts
with mergiraf first (`jj resolve --tool mergiraf`); `toolkit load-shell` puts
it on PATH.
