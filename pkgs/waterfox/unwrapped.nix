# Waterfox's binary release, unwrapped: the tarball's tree in lib/waterfox,
# ELF interpreters and runpaths fixed by autoPatchelf. Settings live in
# packages/waterfox-drv.nix, which copies the launchers next to its own distribution files;
# this package wraps nothing.
{
  lib,
  stdenv,
  src,
  version,
  autoPatchelfHook,
  alsa-lib,
  dbus-glib,
  gtk3,
  libxtst,
  # dlopen'd at run time, so autoPatchelf cannot see them.
  curl,
  ffmpeg,
  libGL,
  libnotify,
  libpulseaudio,
  libva,
  pciutils,
  pipewire,
  udev,
}:
stdenv.mkDerivation {
  pname = "waterfox-unwrapped";
  inherit version src;

  nativeBuildInputs = [autoPatchelfHook];
  buildInputs = [
    alsa-lib
    dbus-glib
    gtk3
    libxtst
  ];
  runtimeDependencies = [
    curl
    ffmpeg
    libGL
    libnotify
    libpulseaudio
    libva.out
    pciutils
    udev
  ];
  appendRunpaths = ["${pipewire}/lib"];
  # The tarball's ELF carry hand-laid sections that a rewrite can corrupt.
  patchelfFlags = ["--no-clobber-old-sections"];

  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib
    cp -r . $out/lib/waterfox
    # Updates come from the pin, never from the browser.
    rm -f $out/lib/waterfox/updater $out/lib/waterfox/updater.ini $out/lib/waterfox/update-settings.ini
    for size in 16 32 48 64 128; do
      icon=$out/lib/waterfox/browser/chrome/icons/default/default$size.png
      if [ -f "$icon" ]; then
        install -Dm444 "$icon" $out/share/icons/hicolor/''${size}x''${size}/apps/waterfox.png
      fi
    done
    runHook postInstall
  '';

  meta = {
    description = "Privacy-focused web browser (binary release, unwrapped)";
    homepage = "https://www.waterfox.net/";
    changelog = "https://github.com/BrowserWorks/waterfox/releases/tag/${version}";
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    license = lib.licenses.mpl20;
    platforms = ["x86_64-linux"];
    mainProgram = "waterfox";
  };
}
