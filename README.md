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

Without flakes:

```sh
nix-build -A example-package
```

## Layout

- `pkgs/` — packages, registered in `default.nix`
- `lib/`, `overlays/`, `nixos-modules/` — library functions, overlays, NixOS modules
- `ci.nix` — the buildable and cacheable package set
- `nix/tamal/` — every pin, managed by [nixtamal](https://nixtamal.toast.al); see `AGENTS.md`

## Maintenance

```nu
overlay use --prefix toolkit.nu
toolkit update  # refresh every pin
```

CI builds every package except those marked `meta.broken`, unfree, or
`preferLocalBuild`; the last are built but not cached.
