# Agent rules

## Pins

Every hard pin belongs to nixtamal. A hard pin is anything that fixes a
revision or hash of an external source: nixpkgs, a package `src`, a patch.

- Declare it as an input in `nix/tamal/manifest.kdl`. Its `fresh-cmd` is the
  script that fetches the desired stability level; the lock records what it
  returned.
- Consume it through the loader: `default.nix` binds
  `inputs = import ./nix/tamal {bootstrap-pkgs = pkgs;}` and passes
  `inputs.<name>` to the package as `src`.
- Never add flake inputs, `fetch*` calls with a literal `rev` or `hash`, or
  `<nixpkgs>` lookups.
- Never edit `nix/tamal/default.nix`, `lock.json`, or `darcs_context/`;
  nixtamal rewrites them.

| Input | Stability level | `fresh-cmd` source |
| --- | --- | --- |
| `nixpkgs` | `nixpkgs-unstable` channel release | `https://channels.nixos.org/nixpkgs-unstable` redirect |
| `nixtamal` | darcs `next` head | `https://darcs.toastal.in.th/nixtamal/next/_darcs/weak_hash` |

`nixpkgs` must stay `fetch-time=eval` with a SHA-256 hash: the loader
bootstraps from it, and `default.nix` imports it during evaluation.

To change a stability level, edit the input's source and `fresh-cmd`, then
refresh. To hold a pin, mark the input `frozen=#true`.

## Package patches

Optional patches live in `pkgs/<package>/patches/` and are opt-in through the
package's `enabledPatches` argument; evaluating the package without them prints
the ones available. `nixtamal`'s `shell` patch (`fresh-cmd shell="nu"`) comes
from midgard-flakes, rebased onto the pinned `next`. When a refresh moves
`next`, rebuild with the patch and rebase it if it no longer applies.

`nixtamal`'s `packages` argument puts tools first on the runner's PATH, ahead
of its prefetchers and the caller's PATH, such as `[nushell]`.
`default.devShell` enables the `shell` patch with `packages = [nushell]`.

## Commands

```nu
overlay use --prefix toolkit.nu
toolkit update           # lock new inputs, refresh every unfrozen pin
toolkit update nixtamal  # refresh one input
toolkit load-shell       # repo tooling (this repo's nixtamal) in scope
toolkit load-shell nixtamal  # plus each named package's devShell
```

A toolkit command that needs a package's dev shell starts with
`load-shell <package>`.

`nix fmt .` formats with alejandra and skips `nix/tamal/`.
