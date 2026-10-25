# Overlays

## `mozilla`

Waterfox and nixpkgs' LibreWolf with their settings baked into the install,
through the shared wrapper `pkgs/mozilla/wrap.nix`:

```nix
nixpkgs.overlays = [ inputs.larandar-nur.overlays.mozilla ];
environment.systemPackages = [
  (pkgs.librewolf.override {
    preferences."browser.startup.page" = 3;
    policies.DisableTelemetry = true;
  })
];
```

`librewolf` wraps the host nixpkgs' `librewolf-unwrapped`; `waterfox` is this
repository's pinned release. The overlay replaces `librewolf`.

### LibreWolf's own settings

LibreWolf ships its hardening as two files in its source repository, which
nixpkgs passes on as `librewolf-unwrapped.extraPrefsFiles` and
`extraPoliciesFiles`
([librewolf.nix](https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/li/librewolf-unwrapped/librewolf.nix)):

| File | Upstream (tag `158.0.1-1`) |
| --- | --- |
| `librewolf.cfg`: preferences | [settings/librewolf.cfg](https://librewolf.dev/librewolf/source/src/tag/158.0.1-1/settings/librewolf.cfg) |
| `local-settings.js`: nixpkgs strips its `general.config.filename` line | [settings/defaults/pref/local-settings.js](https://librewolf.dev/librewolf/source/src/tag/158.0.1-1/settings/defaults/pref/local-settings.js) |
| `policies.json`: enterprise policies | [settings/distribution/policies.json](https://librewolf.dev/librewolf/source/src/tag/158.0.1-1/settings/distribution/policies.json) |

The tag follows nixpkgs' `librewolf-unwrapped` version; replace it in the links
for another release.

### How they are registered

The wrapper keeps the browser's own files beneath the settings:

- Preferences: `basePreferenceFiles` are concatenated, in order, into
  `lib/<browser>/<browser>.cfg`, and the `preferences` setting is appended
  after them, so its values win. `defaults/pref/autoconfig.js` registers the
  file with `general.config.filename`; AutoConfig skips the file's first line,
  which the wrapper writes as a comment.
- Policies: `basePolicyFiles` and the `policies` setting are deep-merged with
  `jq` at build time into `lib/<browser>/distribution/policies.json`, later
  ones winning. Merging at build time keeps evaluation free of
  import-from-derivation, since these files come from a fetched source.

The overlay registers LibreWolf's files as:

```nix
librewolf = final.callPackage ../pkgs/mozilla/wrap.nix {
  unwrapped = prev.librewolf-unwrapped;
  binaryName = "librewolf";
  applicationName = "LibreWolf";
  basePreferenceFiles = prev.librewolf-unwrapped.extraPrefsFiles;
  basePolicyFiles = prev.librewolf-unwrapped.extraPoliciesFiles;
};
```

To register files of your own beneath the settings, override the lists:

```nix
pkgs.librewolf.override (old: {
  basePreferenceFiles = old.basePreferenceFiles ++ [ ./extra.cfg ];
  basePolicyFiles = old.basePolicyFiles ++ [ ./extra-policies.json ];
})
```

An extra `.cfg` uses AutoConfig's calls (`pref`, `defaultPref`, `lockPref`);
an extra policies file is `{ "policies": { ... } }`.
