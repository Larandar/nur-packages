# A Mozilla-family browser (Waterfox, LibreWolf) with its settings baked into the install. The tree is a symlink farm
# over the unwrapped browser, except the launchers, which are copied: the browser finds its application directory
# from its own executable, so they must live beside this package's distribution/ and AutoConfig files. The browser's
# own preferences and policies (`basePreferenceFiles`, `basePolicyFiles`, such as LibreWolf's) come first; these
# settings go on top of them.
#
# - policies:    attrset, written as distribution/policies.json.
# - preferences: see settings.nix; written as AutoConfig (waterfox.cfg), so
#                any pref can be locked, not only those policies expose.
# - extensions:  list of { id; xpi; }, force-installed from the store.
# - chrome:      a directory holding userChrome.css and userContent.css,
#                registered by AutoConfig as user sheets of the install: every
#                profile wears them from its first launch, with nothing copied
#                into it.
# - searchEngine: { name; url; } (url carries `{searchTerms}`), added and
#                made the locked default; null leaves the stock engines.
#                SearchEngines is an ESR policy, and Waterfox is ESR-based.
# - desktopEntry: makeDesktopItem fields over the default entry (desktopName,
#                genericName, comment, categories, mimeTypes, ...).
# - icon:        an image path for the entry; null keeps Waterfox's own.
# - wmClass:     null keeps Waterfox's default window class; a string runs
#                the entry with `--name <wmClass>` and declares it as
#                StartupWMClass, for WM rules that must tell this apart.
# - newTabCommand: null, or an argv (absolute program first) that Ctrl+T
#                runs instead of opening a tab.
# - loginStorage: null keeps logins.json; "multipass" puts the login
#                manager's storage on the user's multipass service
#                (ad.lar.MultiPass), the browser's login UI unchanged.
# - remote:      { users = { <name> = <basePort>; }; rangeSize; launcherAlias; }
#                starts the browser, for a listed user only, with its remote
#                debugging interface (WebDriver BiDi) on the first free
#                loopback port of that user's range, and records the port in
#                $XDG_RUNTIME_DIR/waterfox-remote/<profile>.port for
#                waterfox-remote. Also adds a search engine under the alias
#                (default `@l`) whose requests waterfox-remote hands to the
#                launcher. The wrapper does not firewall: ANY LOCAL PROCESS,
#                ANY USER, REACHING THE PORT DRIVES THE BROWSER unless
#                something (the NixOS module) refuses other users. null: no
#                remote interface for anyone.
{
  lib,
  stdenv,
  makeDesktopItem,
  copyDesktopItems,
  wrapGAppsHook3,
  makeShellWrapper,
  gtk3,
  coreutils,
  jq,
  # The browser: a tree with lib/<binaryName>/{<binaryName>,<binaryName>-bin}.
  unwrapped,
  binaryName,
  applicationName,
  # AutoConfig files and `{ policies; }` JSON files the browser itself ships, applied beneath these settings.
  basePreferenceFiles ? [],
  basePolicyFiles ? [],
  passthru ? {},
  policies ? {},
  preferences ? {},
  extensions ? [],
  chrome ? null,
  searchEngine ? null,
  desktopEntry ? {},
  icon ? null,
  wmClass ? null,
  remote ? null,
  newTabCommand ? null,
  loginStorage ? null,
  # nixpkgs' wrapFirefox interface, so home-manager's Firefox modules and NixOS's programs.firefox can drive this
  # package: `cfg` is accepted and ignored, `extraPolicies` merge over `policies`, `extraPrefs` and `extraPrefsFiles`
  # go after `preferences`.
  cfg ? {},
  extraPolicies ? {},
  extraPrefs ? "",
  extraPrefsFiles ? [],
  nativeMessagingHosts ? [],
  pkcs11Modules ? [],
  # Whether the browser reads native messaging hosts and PKCS #11 modules from MOZ_SYSTEM_DIR (nixpkgs' patch). As in
  # wrapFirefox, off unless the browser says so: hosts are then linked into the user's directory at launch.
  hasMozSystemDirPatch ? unwrapped.hasMozSystemDirPatch or false,
}: let
  hasMozSystemDir = hasMozSystemDirPatch;
  hosts = map lib.getBin (lib.unique nativeMessagingHosts);
  settings = import ./settings.nix {inherit lib;};
  remote' =
    if remote == null
    then null
    else
      {
        users = {};
        rangeSize = 10;
        launcherAlias = "@l";
      }
      // remote;
  # Runs in the bash wrapper before exec. Profile names are the `-P` name or
  # the `--profile` directory's basename, outside [A-Za-z0-9_-] mapped to
  # `_`: the same name waterfox-remote's `--profile` takes. A port already
  # recorded for the profile and answering is kept, so a second launch that
  # remoting hands to the running browser does not move the record.
  remotePort = ''
    waterfox_remote_args=
    case "$(${coreutils}/bin/id -un)" in
      ${lib.concatStrings (
      lib.mapAttrsToList (user: base: ''
        ${lib.escapeShellArg user}) waterfox_remote_base=${toString base} ;;
      '')
      remote'.users
    )}
      *) waterfox_remote_base= ;;
    esac
    if [ -n "$waterfox_remote_base" ] && [ -n "''${XDG_RUNTIME_DIR-}" ]; then
      waterfox_remote_profile=default
      waterfox_remote_prev=
      for waterfox_remote_arg in "$@"; do
        case "$waterfox_remote_prev" in
          -P|-p) waterfox_remote_profile=$waterfox_remote_arg ;;
          --profile|-profile)
            waterfox_remote_profile=''${waterfox_remote_arg%/}
            waterfox_remote_profile=''${waterfox_remote_profile##*/} ;;
        esac
        waterfox_remote_prev=$waterfox_remote_arg
      done
      waterfox_remote_profile=$(printf %s "$waterfox_remote_profile" | ${coreutils}/bin/tr -c 'A-Za-z0-9_-' _)
      waterfox_remote_dir=$XDG_RUNTIME_DIR/waterfox-remote
      ${coreutils}/bin/mkdir -p -m 700 "$waterfox_remote_dir"
      waterfox_remote_file=$waterfox_remote_dir/$waterfox_remote_profile.port
      waterfox_remote_port=
      if [ -f "$waterfox_remote_file" ]; then
        waterfox_remote_seen=$(<"$waterfox_remote_file")
        if (exec 3<>"/dev/tcp/127.0.0.1/$waterfox_remote_seen") 2>/dev/null; then
          waterfox_remote_port=$waterfox_remote_seen
        fi
      fi
      waterfox_remote_i=0
      while [ -z "$waterfox_remote_port" ] && [ "$waterfox_remote_i" -lt ${toString remote'.rangeSize} ]; do
        waterfox_remote_try=$((waterfox_remote_base + waterfox_remote_i))
        if ! (exec 3<>"/dev/tcp/127.0.0.1/$waterfox_remote_try") 2>/dev/null; then
          waterfox_remote_port=$waterfox_remote_try
        fi
        waterfox_remote_i=$((waterfox_remote_i + 1))
      done
      if [ -n "$waterfox_remote_port" ]; then
        printf '%s\n' "$waterfox_remote_port" > "$waterfox_remote_file"
        waterfox_remote_args="--remote-debugging-port $waterfox_remote_port"
      fi
    fi
  '';
  engines =
    lib.optional (searchEngine != null) {
      Name = searchEngine.name;
      URLTemplate = searchEngine.url;
      Method = "GET";
    }
    ++ lib.optional (remote' != null) {
      Name = "Launcher";
      Alias = remote'.launcherAlias;
      # Never fetched: waterfox-remote intercepts and fails it in the browser,
      # and with the daemon down `.invalid` never resolves (RFC 6761).
      URLTemplate = "https://launcher.invalid/?q={searchTerms}";
      Method = "GET";
    };
  # BiDi only, and without the automation profile: the remote agent would
  # otherwise apply its "recommended" test preferences to a daily browser.
  remotePreferences = lib.optionalAttrs (remote' != null) {
    "remote.active-protocols" = 1;
    "remote.prefs.recommended" = false;
  };
  # Updates come from the pin; the browser never offers its own.
  allPolicies =
    lib.recursiveUpdate (
      {
        DisableAppUpdate = true;
        ExtensionSettings = lib.listToAttrs (
          map (
            extension:
              lib.nameValuePair extension.id {
                installation_mode = "force_installed";
                install_url = "file://${extension.xpi}";
              }
          )
          extensions
        );
      }
      // lib.optionalAttrs (engines != []) {
        SearchEngines =
          {
            Add = engines;
            PreventInstalls = true;
          }
          // lib.optionalAttrs (searchEngine != null) {Default = searchEngine.name;};
      }
    )
    (lib.recursiveUpdate policies extraPolicies);
  policiesJson = builtins.toJSON {policies = allPolicies;};
  # The chrome rides in AutoConfig, which runs privileged at every start
  # (the sandbox is off for it below): the stylesheet service applies a user
  # sheet to every window and document, whichever profile is open.
  registerChrome = ''

    // The install's chrome, registered as user sheets for every profile.
    {
      const sss = Components.classes["@mozilla.org/content/style-sheet-service;1"].getService(Components.interfaces.nsIStyleSheetService);
      const io = Components.classes["@mozilla.org/network/io-service;1"].getService(Components.interfaces.nsIIOService);
      for (const name of ["userChrome.css", "userContent.css"]) {
        try {
          const uri = io.newURI("file://${chrome}/" + name);
          if (!sss.sheetRegistered(uri, sss.USER_SHEET)) sss.loadAndRegisterSheet(uri, sss.USER_SHEET);
        } catch (e) {
          Components.utils.reportError(e);
        }
      }
    }
  '';
  # Ctrl+T runs a command instead of opening a tab: the key gives up its
  # command, and its own command event starts the process. Every window,
  # from its delayed startup on.
  newTabHook = ''

    // Ctrl+T runs `argv` instead of opening a tab.
    {
      const argv = ${builtins.toJSON newTabCommand};
      const run = () => {
        const file = Components.classes["@mozilla.org/file/local;1"].createInstance(Components.interfaces.nsIFile);
        file.initWithPath(argv[0]);
        const process = Components.classes["@mozilla.org/process/util;1"].createInstance(Components.interfaces.nsIProcess);
        process.init(file);
        process.runAsync(argv.slice(1), argv.length - 1);
      };
      const observers = Components.classes["@mozilla.org/observer-service;1"].getService(Components.interfaces.nsIObserverService);
      observers.addObserver({
        observe(win) {
          const key = win.document.getElementById("key_newNavigatorTab");
          if (!key) return;
          key.removeAttribute("command");
          key.addEventListener("command", (event) => {
            event.stopPropagation();
            run();
          });
        },
      }, "browser-delayed-startup-finished");
    }
  '';
  # Installed before the login manager first asks for its storage: a
  # resource alias for the module in the store, and the factory replaced.
  multipassStorage = ''

    // The login manager's storage is the user's multipass service.
    {
      Components.classes["@mozilla.org/network/protocol;1?name=resource"]
        .getService(Components.interfaces.nsIResProtocolHandler)
        .setSubstitution("waterfox-multipass", Services.io.newURI("file://${./multipass-storage}/"));
      const { LoginManagerStorage } = ChromeUtils.importESModule("resource://passwordmgr/passwordstorage.sys.mjs");
      const { MultipassStorage } = ChromeUtils.importESModule("resource://waterfox-multipass/storage.sys.mjs");
      LoginManagerStorage.create = (callback) => {
        const storage = new MultipassStorage();
        storage.initialize().then(() => callback?.());
        return storage;
      };
    }
  '';
  autoConfig = assert lib.assertOneOf "loginStorage" loginStorage [
    null
    "multipass"
  ];
    settings.autoConfig (remotePreferences // preferences)
    + lib.optionalString (chrome != null) registerChrome
    + lib.optionalString (newTabCommand != null) newTabHook
    + lib.optionalString (loginStorage == "multipass") multipassStorage
    + lib.optionalString (extraPrefs != "") "\n${extraPrefs}\n";
  nameFlag = lib.optionalString (wmClass != null) " --name ${lib.escapeShellArg wmClass}";
in
  lib.warnIf (pkcs11Modules != [] && !hasMozSystemDir)
  "${binaryName}: pkcs11Modules need MOZ_SYSTEM_DIR, which this build does not read; use the SecurityDevices policy"
  stdenv.mkDerivation {
    pname = binaryName;
    inherit (unwrapped) version;
    dontUnpack = true;

    nativeBuildInputs = [
      copyDesktopItems
      # The shell wrapper: the C one wrapGAppsHook3 now defaults to rejects the
      # `--run` snippets and the `$var` in `--add-flags` this wrapper carries.
      (wrapGAppsHook3.override {makeWrapper = makeShellWrapper;})
    ];
    buildInputs = [gtk3];

    desktopItems = [
      (makeDesktopItem (
        {
          name = binaryName;
          exec = "${binaryName}${nameFlag} %U";
          icon =
            if icon == null
            then binaryName
            else "${icon}";
          desktopName = applicationName;
          genericName = "Web Browser";
          categories = [
            "Network"
            "WebBrowser"
          ];
          mimeTypes = [
            "text/html"
            "text/xml"
            "application/xhtml+xml"
            "x-scheme-handler/http"
            "x-scheme-handler/https"
          ];
          actions.new-private-window = {
            name = "New Private Window";
            exec = "${binaryName}${nameFlag} --private-window %U";
          };
        }
        // lib.optionalAttrs (wmClass != null) {startupWMClass = wmClass;}
        // desktopEntry
      ))
    ];

    inherit policiesJson autoConfig;
    passAsFile = [
      "policiesJson"
      "autoConfig"
    ];

    installPhase = ''
      runHook preInstall
      app=$out/lib/${binaryName}
      mkdir -p $out/lib $out/bin
      cp -rs --no-preserve=mode ${unwrapped}/lib/${binaryName} $app
      for launcher in ${binaryName} ${binaryName}-bin; do
        cp --remove-destination "$(readlink -f "$app/$launcher")" "$app/$launcher"
        chmod +x "$app/$launcher"
      done

      mkdir -p $app/distribution $app/defaults/pref
      rm -f $app/distribution/policies.json
      # The browser's own policies beneath these: objects merge, these win.
      ${jq}/bin/jq -c -s 'reduce .[] as $policies ({}; . * $policies)' ${lib.escapeShellArgs basePolicyFiles} "$policiesJsonPath" \
        > $app/distribution/policies.json
      cat > $app/defaults/pref/autoconfig.js <<'JS'
      pref("general.config.filename", "${binaryName}.cfg");
      pref("general.config.obscure_value", 0);
      ${lib.optionalString (
        chrome != null || newTabCommand != null || loginStorage != null
      ) ''pref("general.config.sandbox_enabled", false);''}
      JS
      # AutoConfig skips its first line; then the browser's own files, then these settings.
      {
        echo "// ${applicationName} settings: the browser's own, then this install's."
        for file in ${lib.escapeShellArgs basePreferenceFiles}; do cat "$file"; echo; done
        cat "$autoConfigPath"
        for file in ${lib.escapeShellArgs extraPrefsFiles}; do echo; cat "$file"; done
      } > $app/${binaryName}.cfg

      mkdir -p $out/lib/mozilla/native-messaging-hosts $out/lib/mozilla/pkcs11-modules
      for host in ${lib.escapeShellArgs hosts}; do
        ln -sLt $out/lib/mozilla/native-messaging-hosts $host/lib/mozilla/native-messaging-hosts/*
      done
      for module in ${lib.escapeShellArgs pkcs11Modules}; do
        ln -sLt $out/lib/mozilla/pkcs11-modules $module/lib/mozilla/pkcs11-modules/*
      done

      # share/ stays a real directory: copyDesktopItems writes into it.
      mkdir -p $out/share
      if [ -d ${unwrapped}/share/icons ]; then
        ln -s ${unwrapped}/share/icons $out/share/icons
      else
        for size in 16 32 48 64 128; do
          png=$app/browser/chrome/icons/default/default$size.png
          if [ -f "$png" ]; then
            install -Dm444 "$png" $out/share/icons/hicolor/''${size}x''${size}/apps/${binaryName}.png
          fi
        done
      fi
      ln -s $app/${binaryName} $out/bin/${binaryName}
      runHook postInstall
    '';

    # One profile across versions: without legacy profiles each store path is
    # a new install, and a new install gets a new profile.
    # MOZ_APP_LAUNCHER is what "make default browser" writes into its desktop
    # entry; unset, that entry execs this store path's <binaryName>-bin, past this
    # wrapper and stale after the next update.
    preFixup = ''
      gappsWrapperArgs+=(
        --set MOZ_LEGACY_PROFILES 1
        --set MOZ_ALLOW_DOWNGRADE 1
        --set-default MOZ_APP_LAUNCHER ${binaryName}
        ${
        if hasMozSystemDir
        then "--set MOZ_SYSTEM_DIR $out/lib/mozilla"
        else
          lib.optionalString (hosts != []) (lib.escapeShellArgs [
            "--run"
            "mkdir -p \${MOZ_HOME:-~/.mozilla}/native-messaging-hosts"
            "--run"
            "ln -sfLt \${MOZ_HOME:-~/.mozilla}/native-messaging-hosts ${placeholder "out"}/lib/mozilla/native-messaging-hosts/*"
          ])
      }
        ${lib.optionalString (remote' != null) ''
        --run ${lib.escapeShellArg remotePort}
        --add-flags '$waterfox_remote_args'
      ''}
      )
    '';

    passthru =
      {
        inherit unwrapped allPolicies preferences;
        remote = remote';
      }
      // passthru;

    meta =
      unwrapped.meta
      // {
        description = "${applicationName}, with declarative policies and preferences";
      };
  }
