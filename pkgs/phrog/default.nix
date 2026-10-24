# Opt-in patches: `phrog.override {enabledPatches = ["hide-numpad" "greeter-rotation"];}`.
{
  lib,
  rustPlatform,
  pkg-config,
  wrapGAppsHook3,
  glib,
  gtk3,
  libhandy,
  phosh,
  gettext,
  wlr-randr,
  src,
  version,
  enabledPatches ? [],
}: let
  available = {
    # `PHROG_HIDE_NUMPAD` hides the digit keys of the keypad libphosh inherits from phones.
    hide-numpad = ./patches/hide-numpad.patch;
    # After the initial lock, rotate `PHROG_OUTPUT` to `PHROG_OUTPUT_TRANSFORM` with wlr-randr.
    greeter-rotation = ./patches/greeter-rotation.patch;
  };

  unknown = lib.subtractLists (lib.attrNames available) enabledPatches;
  disabled = lib.subtractLists enabledPatches (lib.attrNames available);
in
  if unknown != []
  then throw "phrog: unknown patches ${toString unknown}; available: ${toString (lib.attrNames available)}"
  else
    rustPlatform.buildRustPackage {
      pname = "phrog";
      # Forced only when the derivation is used, so `.override` on the default stays quiet.
      version =
        if disabled == []
        then version
        else lib.info "phrog: optional patches not enabled: ${toString disabled}; enable with `phrog.override {enabledPatches = [...];}`" version;
      inherit src;

      inherit (lib.importJSON ./lock.nuon) cargoHash;

      patches = map (name: available.${name}) enabledPatches;
      postPatch = lib.optionalString (lib.elem "greeter-rotation" enabledPatches) ''
        substituteInPlace src/shell.rs --replace-fail @wlrRandr@ ${lib.getExe wlr-randr}
      '';

      nativeBuildInputs = [
        pkg-config
        wrapGAppsHook3
        glib
      ];
      buildInputs = [
        gtk3
        libhandy
        phosh
        gettext
      ];
      GETTEXT_SYSTEM = "1";

      preBuild = ''
        export HOME="$TMPDIR/phrog-home"
        mkdir -p "$HOME"
      '';

      # The upstream integration suite needs a running compositor and seat.
      doCheck = false;

      postInstall = ''
        install -Dm644 data/mobi.phosh.phrog.gschema.xml -t "$out/share/glib-2.0/schemas"
        install -Dm644 data/00_mobi.phosh.Phrog.gschema.override -t "$out/share/glib-2.0/schemas"
        glib-compile-schemas "$out/share/glib-2.0/schemas"
        install -Dm644 data/phrog.session -t "$out/share/gnome-session/sessions"
        install -Dm644 data/mobi.phosh.Phrog.desktop -t "$out/share/applications"
        substituteInPlace "$out/share/applications/mobi.phosh.Phrog.desktop" \
          --replace-fail 'Exec=phrog' "Exec=$out/bin/phrog"
        install -Dm644 data/mobi.phosh.Phrog.service data/mobi.phosh.Phrog.target -t "$out/lib/systemd/user"
        substituteInPlace "$out/lib/systemd/user/mobi.phosh.Phrog.service" \
          --replace-fail 'ExecStart=phrog' "ExecStart=$out/bin/phrog"
        install -Dm644 data/systemd-session.conf "$out/lib/systemd/user/gnome-session@phrog.target.d/session.conf"
        mkdir -p "$out/share/phrog/autostart"
      '';

      meta = {
        description = "Touch-friendly Phosh greeter for greetd";
        homepage = "https://github.com/samcday/phrog";
        license = lib.licenses.gpl3Only;
        platforms = lib.platforms.linux;
        mainProgram = "phrog";
      };
    }
