//! waterfox-remote — the launcher and Waterfox, both ways, over WebDriver BiDi.
//!
//! Firefox-family browsers accept ONE WebDriver session at a time, so the
//! session belongs to a daemon and everything else talks to the daemon, over
//! a standard IPC rather than a private one:
//!
//! - Varlink (`ad.lar.WaterfoxRemote`) on the profile's unix socket, always:
//!   `varlinkctl call <socket> ad.lar.WaterfoxRemote.Tabs {}` works as is;
//! - D-Bus (`ad.lar.WaterfoxRemote1.<profile>` on the session bus) with
//!   `--dbus`, for shells and launchers that speak it.
//!
//! Both serve the same calls: `Tabs`, `Focus`, `Open`, and the launcher
//! queries — requests to `https://launcher.invalid/?q=…` (the browser's `@l`
//! alias) that the daemon fails before they leave the machine, steps the tab
//! back from, and hands to the configured launcher command, to Varlink
//! `WatchLauncher` streams and to the D-Bus `LauncherQuery` signal.
//!
//! PER USER, PER PROFILE. Everything lives in the user's runtime directory
//! (`/run/user/<uid>`, mode 0700), under `waterfox-remote/`: `<profile>.sock`
//! is this daemon's socket, `<profile>.port` is where the Waterfox wrapper
//! wrote the BiDi port it started that profile with. One daemon per profile;
//! a second one refuses to start rather than steal the socket.
//!
//! The browser's end is TCP on loopback — Waterfox offers nothing else, and
//! BiDi has no authentication — so the NixOS module gives each user a port
//! range and a firewall rule that refuses every other user's connections to
//! it.
mod bidi;
mod core;
mod dbus;
mod http;
mod mcp;
mod varlink;

use crate::bidi::Bidi;
use crate::core::{Core, LauncherQuery, Profiles};
use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use serde_json::json;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::{UnixListener, UnixStream};

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// The Waterfox profile a client command talks to (`-P <name>`, or
    /// `--profile`'s directory name); `default` when the browser was started
    /// without one. The daemon serves every profile.
    #[arg(long, env = "WATERFOX_REMOTE_PROFILE", default_value = "default")]
    profile: String,
    /// The daemon's Varlink socket; defaults to the user's in the runtime dir.
    #[arg(long, env = "WATERFOX_REMOTE_SOCKET")]
    socket: Option<PathBuf>,
    #[command(subcommand)]
    command: Command,
}

/// `<profile>=<port>`: a profile pinned to a BiDi port instead of the one
/// the wrapper records.
fn pinned_port(raw: &str) -> Result<(String, u16), String> {
    let (profile, port) = raw.split_once('=').ok_or("expected <profile>=<port>")?;
    valid_profile(profile).map_err(|e| e.to_string())?;
    Ok((profile.to_owned(), port.parse().map_err(|_| "bad port")?))
}

#[derive(Subcommand)]
enum Command {
    /// Serve every profile: each as the wrapper records its port (found at
    /// run time, so a profile created while the daemon runs is served too).
    Daemon {
        /// `<profile>=<port>`: pin a profile's BiDi port (tests, odd setups).
        #[arg(long = "port", value_parser = pinned_port)]
        ports: Vec<(String, u16)>,
        /// Also serve D-Bus on the session bus.
        #[arg(long)]
        dbus: bool,
        /// Also serve MCP on `mcp.sock`, cut to this policy file (JSON:
        /// `profiles.<name or *>.{tools, sites}`).
        #[arg(long)]
        mcp_policy: Option<PathBuf>,
        /// The search door's socket (searchwala-calf), for MCP `search` and
        /// page parsing.
        #[arg(long)]
        search_socket: Option<PathBuf>,
        /// blocky's HTTP API (`http://127.0.0.1:4000`), for MCP DNS calls.
        #[arg(long)]
        blocky_url: Option<String>,
        /// How to start a profile that `Open` finds closed, one argument per
        /// occurrence (`--browser=systemd-run --browser=--user …`); `-P
        /// <profile>` and `--headless` are appended. None: `Open` on a closed
        /// profile fails.
        #[arg(long = "browser", allow_hyphen_values = true)]
        browser: Vec<String>,
        /// Launcher command; the query is appended as its last argument, the
        /// profile is in WATERFOX_REMOTE_PROFILE.
        #[arg(long = "launcher", num_args = 1.., allow_hyphen_values = true)]
        launcher: Vec<String>,
    },
    /// The profiles the daemon has seen, as JSON lines: name, connected.
    Profiles,
    /// Top-level tabs as JSON lines: context, url, title.
    Tabs,
    /// Bring a tab (by context id) to the front.
    Focus { context: String },
    /// Open a URL in a new tab; a closed profile is started first.
    Open {
        url: String,
        /// Start a closed profile headless.
        #[arg(long)]
        headless: bool,
    },
    /// Print each launcher query as it arrives, as JSON lines: profile, query.
    Watch,
    /// MCP on stdio, bridged to the daemon's MCP socket.
    Mcp,
}

/// `$XDG_RUNTIME_DIR/waterfox-remote`, the per-user directory the wrapper
/// and the daemon share. No fallback to a shared temp dir: without a private
/// runtime directory there is nowhere safe to put either file.
fn state_dir() -> Result<PathBuf> {
    let runtime = std::env::var_os("XDG_RUNTIME_DIR").context("XDG_RUNTIME_DIR is not set")?;
    Ok(PathBuf::from(runtime).join("waterfox-remote"))
}

fn valid_profile(profile: &str) -> Result<()> {
    if profile.is_empty()
        || !profile
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        bail!("invalid profile name {profile:?} (expected [A-Za-z0-9_-]+)");
    }
    Ok(())
}

fn recorded_port(path: &Path) -> Option<u16> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

enum PortSource {
    Fixed(u16),
    Recorded(PathBuf),
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    valid_profile(&cli.profile)?;
    let socket = match cli.socket {
        Some(socket) => socket,
        None => state_dir()?.join("varlink.sock"),
    };
    let method = |member: &str| format!("{}.{member}", varlink::INTERFACE);
    let profile = json!(cli.profile);
    match cli.command {
        Command::Daemon {
            ports,
            dbus,
            mcp_policy,
            search_socket,
            blocky_url,
            browser,
            launcher,
        } => {
            let mcp = match mcp_policy {
                Some(path) => Some((
                    mcp::Policies::load(&path)?,
                    state_dir()?.join("mcp.sock"),
                    mcp::Backends {
                        search: search_socket.map(http::Endpoint::Unix),
                        blocky: blocky_url.as_deref().map(http::Endpoint::parse),
                    },
                )),
                None => None,
            };
            daemon(socket, ports, dbus, mcp, browser, launcher).await
        }
        Command::Profiles => {
            varlink::call(&socket, &method("Profiles"), json!({}), false, |reply| {
                for profile in reply["profiles"].as_array().into_iter().flatten() {
                    println!("{profile}");
                }
            })
            .await
        }
        Command::Tabs => {
            varlink::call(
                &socket,
                &method("Tabs"),
                json!({ "profile": profile }),
                false,
                |reply| {
                    for tab in reply["tabs"].as_array().into_iter().flatten() {
                        println!("{tab}");
                    }
                },
            )
            .await
        }
        Command::Focus { context } => {
            varlink::call(
                &socket,
                &method("Focus"),
                json!({ "profile": profile, "context": context }),
                false,
                |_| {},
            )
            .await
        }
        Command::Open { url, headless } => {
            varlink::call(
                &socket,
                &method("Open"),
                json!({ "profile": profile, "url": url, "headless": headless }),
                false,
                |reply| {
                    println!("{}", reply["context"].as_str().unwrap_or_default());
                },
            )
            .await
        }
        Command::Watch => {
            varlink::call(
                &socket,
                &method("WatchLauncher"),
                json!({}),
                true,
                |reply| {
                    println!("{reply}");
                },
            )
            .await
        }
        Command::Mcp => mcp::bridge(&state_dir()?.join("mcp.sock")).await,
    }
}

async fn daemon(
    socket: PathBuf,
    ports: Vec<(String, u16)>,
    dbus: bool,
    mcp: Option<(mcp::Policies, PathBuf, mcp::Backends)>,
    browser: Vec<String>,
    launcher: Vec<String>,
) -> Result<()> {
    let dir = state_dir()?;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)
        .with_context(|| format!("creating {}", dir.display()))?;
    // ONE DAEMON PER USER. A live socket means another daemon serves this
    // user's profiles: refuse, never steal it. Only a socket nobody answers
    // on is stale and removed.
    if UnixStream::connect(&socket).await.is_ok() {
        bail!(
            "another waterfox-remote daemon already serves {}",
            socket.display()
        );
    }
    let _ = std::fs::remove_file(&socket);
    let listener =
        UnixListener::bind(&socket).with_context(|| format!("binding {}", socket.display()))?;
    std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600))?;

    let profiles = Profiles::new(browser);
    let launcher = Arc::new(launcher);
    // Every transport serves whether or not any browser is up; calls answer
    // ProfileNotFound or BrowserNotConnected until one is.
    tokio::spawn(varlink::serve(listener, profiles.clone()));
    if let Some((policies, path, backends)) = mcp {
        // The Varlink socket's liveness check above already rules out a
        // second daemon; a leftover MCP socket is stale.
        let _ = std::fs::remove_file(&path);
        let listener =
            UnixListener::bind(&path).with_context(|| format!("binding {}", path.display()))?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        let browser = mcp::Browser::new(profiles.clone(), policies, backends);
        tokio::spawn(async move {
            if let Err(error) = mcp::serve(listener, browser).await {
                eprintln!("waterfox-remote: MCP stopped: {error:#}");
            }
        });
    }
    let _bus = if dbus {
        Some(dbus::serve(profiles.clone()).await?)
    } else {
        None
    };

    for (profile, port) in ports {
        let (core, _) = profiles.adopt(&profile);
        tokio::spawn(session(
            core,
            PortSource::Fixed(port),
            profiles.clone(),
            launcher.clone(),
        ));
    }
    // DISCOVERY. The wrapper writes `<profile>.port` when it starts a
    // profile; each one seen is adopted for good (its session waits while
    // the browser is closed), so a profile created while the daemon runs is
    // served without a restart.
    loop {
        if let Ok(entries) = std::fs::read_dir(&dir) {
            for entry in entries.flatten() {
                let name = entry.file_name();
                let Some(profile) = name.to_str().and_then(|n| n.strip_suffix(".port")) else {
                    continue;
                };
                if valid_profile(profile).is_err() {
                    continue;
                }
                let (core, new) = profiles.adopt(profile);
                if new {
                    eprintln!("waterfox-remote: serving profile {profile}");
                    tokio::spawn(session(
                        core,
                        PortSource::Recorded(entry.path()),
                        profiles.clone(),
                        launcher.clone(),
                    ));
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

/// One profile's BiDi session, for as long as the daemon runs: connect when
/// the browser is up, wait while it is not.
async fn session(
    core: Arc<Core>,
    port: PortSource,
    profiles: Arc<Profiles>,
    launcher: Arc<Vec<String>>,
) {
    // Said once per distinct reason, not every two seconds.
    let mut last_failure = String::new();
    loop {
        let port = match &port {
            PortSource::Fixed(port) => Some(*port),
            PortSource::Recorded(path) => recorded_port(path),
        };
        if let Some(port) = port {
            match Bidi::connect(port).await {
                Err(error) => {
                    let failure = format!("{error:#}");
                    if failure != last_failure {
                        eprintln!("waterfox-remote: {} on port {port}: {failure}", core.name);
                        last_failure = failure;
                    }
                }
                Ok((bidi, events)) => {
                    last_failure.clear();
                    eprintln!("waterfox-remote: {} connected on port {port}", core.name);
                    if let Err(error) = bidi.intercept_launcher().await {
                        eprintln!(
                            "waterfox-remote: {}: launcher intercept not armed: {error:#}",
                            core.name
                        );
                    }
                    core.set_session(Some(bidi.clone())).await;
                    serve_events(&bidi, events, &core.name, &profiles, &launcher).await;
                    core.set_session(None).await;
                    eprintln!("waterfox-remote: {} went away, waiting for it", core.name);
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

/// Until the connection drops: every intercepted launcher query goes to the
/// launcher command and to every listener.
async fn serve_events(
    bidi: &Arc<Bidi>,
    mut events: tokio::sync::mpsc::UnboundedReceiver<serde_json::Value>,
    profile: &str,
    profiles: &Profiles,
    launcher: &[String],
) {
    while let Some(event) = events.recv().await {
        let Some(query) = bidi.take_launcher_query(&event).await else {
            continue;
        };
        let _ = profiles.launcher.send(LauncherQuery {
            profile: profile.to_owned(),
            query: query.clone(),
        });
        if let Some((program, args)) = launcher.split_first() {
            if let Err(error) = tokio::process::Command::new(program)
                .args(args)
                .arg(&query)
                .env("WATERFOX_REMOTE_PROFILE", profile)
                .spawn()
            {
                eprintln!("waterfox-remote: launcher {program}: {error}");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launcher_keeps_its_own_flags() {
        let cli = Cli::try_parse_from([
            "waterfox-remote",
            "--profile",
            "work",
            "daemon",
            "--port",
            "work=9333",
            "--dbus",
            "--browser=systemd-run",
            "--browser=--user",
            "--browser=--",
            "--browser=/bin/waterfox",
            "--launcher",
            "fuzzel",
            "--dmenu",
        ])
        .unwrap();
        assert_eq!(cli.profile, "work");
        match cli.command {
            Command::Daemon {
                ports,
                dbus,
                browser,
                launcher,
                ..
            } => {
                assert_eq!(browser, ["systemd-run", "--user", "--", "/bin/waterfox"]);
                assert_eq!(ports, [("work".to_owned(), 9333)]);
                assert!(dbus);
                assert_eq!(launcher, ["fuzzel", "--dmenu"]);
            }
            _ => panic!("not the daemon"),
        }
    }

    #[test]
    fn profile_names_stay_inside_the_state_dir() {
        for good in ["default", "work", "my_work-2"] {
            assert!(valid_profile(good).is_ok(), "{good:?}");
        }
        for bad in ["", "../x", ".hidden", "a/b", "sp ace", "*"] {
            assert!(valid_profile(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn object_paths_are_valid_for_any_profile() {
        assert_eq!(dbus::path("work"), "/ad/lar/WaterfoxRemote1/work");
        assert_eq!(
            dbus::path("my_work-2"),
            "/ad/lar/WaterfoxRemote1/my_5fwork_2d2"
        );
        for profile in ["work", "2nd", "my_work", "a-b"] {
            assert!(zbus::zvariant::ObjectPath::try_from(dbus::path(profile)).is_ok());
        }
    }

    /// A browser stand-in speaking BiDi's message shapes: one tab, and one
    /// held launcher request sent once the intercept is armed. Records every
    /// method it is called with.
    async fn mock_browser() -> (u16, Arc<tokio::sync::Mutex<Vec<String>>>) {
        use futures_util::{SinkExt, StreamExt};
        use tokio_tungstenite::tungstenite::Message;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen = Arc::new(tokio::sync::Mutex::new(Vec::new()));
        let log = seen.clone();
        tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
            while let Some(Ok(Message::Text(text))) = ws.next().await {
                let call: serde_json::Value = serde_json::from_str(&text).unwrap();
                let method = call["method"].as_str().unwrap().to_owned();
                log.lock().await.push(method.clone());
                let result = match method.as_str() {
                    "browsingContext.getTree" => {
                        json!({"contexts": [{"context": "c1", "url": "https://a.example/", "children": []}]})
                    }
                    "script.evaluate" => {
                        json!({"type": "success", "result": {"type": "string", "value": "A"}})
                    }
                    _ => json!({}),
                };
                let reply = json!({"type": "success", "id": call["id"], "result": result});
                ws.send(Message::Text(reply.to_string().into()))
                    .await
                    .unwrap();
                if method == "network.addIntercept" {
                    let event = json!({"type": "event", "method": "network.beforeRequestSent", "params": {
                        "isBlocked": true, "context": "c1",
                        "request": {"request": "r1", "url": "https://launcher.invalid/?q=hello%20world"},
                    }});
                    ws.send(Message::Text(event.to_string().into()))
                        .await
                        .unwrap();
                }
            }
        });
        (port, seen)
    }

    #[tokio::test]
    async fn serves_tabs_and_hands_over_launcher_queries() {
        let (port, seen) = mock_browser().await;
        let (bidi, mut events) = Bidi::connect(port).await.unwrap();
        bidi.intercept_launcher().await.unwrap();
        let core = Core::new("default");
        core.set_session(Some(bidi.clone())).await;
        assert_eq!(
            core.tabs().await.unwrap(),
            [crate::core::Tab {
                context: "c1".into(),
                url: "https://a.example/".into(),
                title: "A".into(),
            }]
        );
        let event = events.recv().await.unwrap();
        assert_eq!(
            bidi.take_launcher_query(&event).await.as_deref(),
            Some("hello world")
        );
        let seen = seen.lock().await.clone();
        for method in [
            "session.new",
            "network.addIntercept",
            "network.failRequest",
            "browsingContext.traverseHistory",
        ] {
            assert!(
                seen.iter().any(|m| m == method),
                "{method} not called: {seen:?}"
            );
        }
    }

    #[test]
    fn launcher_query_is_the_q_parameter() {
        assert_eq!(
            bidi::launcher_query("https://launcher.invalid/?q=firefox%20settings"),
            "firefox settings"
        );
        assert_eq!(bidi::launcher_query("https://launcher.invalid/"), "");
    }
}
