# nur-packages

**My personal [NUR](https://github.com/nix-community/NUR) repository**,
hosted on [Tangled](https://tangled.org/larandar.tngl.sh/nur-packages).

## Usage

As a flake input:

```nix
inputs.larandar-nur.url = "git+https://tangled.org/larandar.tngl.sh/nur-packages";
```

As a nixpkgs overlay, without the NUR namespace:

```nix
nixpkgs.overlays = [ (import "${inputs.larandar-nur}/overlay.nix") ];
```

Waterfox and LibreWolf with settings baked into the install, through the
`overlays.mozilla` overlay (it replaces nixpkgs' `librewolf`):

```nix
nixpkgs.overlays = [ inputs.larandar-nur.overlays.mozilla ];
environment.systemPackages = [
  (pkgs.librewolf.override {
    preferences."browser.startup.page" = 3;
    policies.DisableTelemetry = true;
  })
];
```

`nixosModules.waterfox` bakes the same settings into a system-wide Waterfox;
`homeModules.waterfox` is home-manager's own Firefox-family module (profiles,
extensions, search, policies) for Waterfox, as `programs.waterfox`. Both
packages also take nixpkgs' `wrapFirefox` arguments (`extraPolicies`,
`extraPrefs`, `nativeMessagingHosts`, ...), so NixOS's `programs.firefox` can
drive them.

On macOS, Waterfox comes from Homebrew and its app stays as the cask installs
it: `darwinModules.waterfox` adds the `waterfox` cask and writes `policies`,
`preferences` (as the `Preferences` policy), `extensions`, `certificates` and
`searchEngine` to the app's system-wide defaults, which Waterfox reads at
start. `homeModules.waterfox` installs no package there and keeps the profiles
in `~/Library/Application Support/Waterfox`, its policies in the user's
defaults.

Without flakes:

```sh
nix-build -A example-package
```

## Layout

- `pkgs/` — packages, registered in `default.nix`
- `lib/`, `overlays/` — library functions, overlays
- `modules/` — modules, exported by `nixos-modules/`, `darwin-modules/` and `home-modules/`
- `ci.nix` — the buildable and cacheable package set
- `nix/tamal/` — every pin, managed by [nixtamal](https://nixtamal.toast.al); see `AGENTS.md`

## Maintenance

```nu
overlay use --prefix toolkit.nu
toolkit update  # refresh every pin
```

CI builds every package except those marked `meta.broken`, unfree, or
`preferLocalBuild`; the last are built but not cached.
