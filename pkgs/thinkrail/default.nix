# ThinkRail's CLI release: a Bun single-file executable that serves the app to a browser.
{
  lib,
  stdenv,
  makeBinaryWrapper,
  patchelf,
  src,
  version,
}:
stdenv.mkDerivation {
  pname = "thinkrail";
  inherit version src;

  nativeBuildInputs = [makeBinaryWrapper] ++ lib.optional stdenv.hostPlatform.isLinux patchelf;

  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  # Bun reads its embedded app from the `.bun` section: a new runpath segfaults it, a strip leaves bare Bun. Only
  # the interpreter changes; glibc's loader finds the rest, all glibc, in its own directory.
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/libexec/thinkrail
    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      patchelf --set-interpreter "$(cat ${stdenv.cc}/nix-support/dynamic-linker)" $out/libexec/thinkrail
    ''}
    # Additional usage sharing is off unless the caller sets the variable empty; crash reports are always sent.
    makeBinaryWrapper $out/libexec/thinkrail $out/bin/thinkrail \
      --set-default THINKRAIL_NO_ANALYTICS 1
    runHook postInstall
  '';

  meta = {
    description = "Agentic IDE around the pi coding agent, with git-worktree workspaces and living specs (binary release)";
    homepage = "https://thinkrail.ai/";
    changelog = "https://github.com/JetBrains/thinkrail/releases/tag/v${version}";
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    license = lib.licenses.asl20;
    platforms = ["x86_64-linux" "aarch64-darwin"];
    mainProgram = "thinkrail";
  };
}
