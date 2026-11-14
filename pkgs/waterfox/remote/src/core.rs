//! What every transport (Varlink, D-Bus, MCP) serves: each profile's tabs
//! and the launcher queries, over whichever BiDi session the daemon holds
//! for that profile right now.
use crate::bidi::Bidi;
use serde::Serialize;
use serde_json::json;
use std::collections::BTreeMap;
use std::fmt;
use std::sync::{Arc, RwLock};
use tokio::sync::{broadcast, Mutex};

#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct Tab {
    pub context: String,
    pub url: String,
    pub title: String,
}

pub struct PageHtml {
    pub title: String,
    pub url: String,
    pub html: String,
    /// Nodes the XPath selected (1 for a whole page).
    pub count: usize,
}

#[derive(Debug)]
pub enum Error {
    /// The daemon does not serve this profile.
    UnknownProfile(String),
    /// No browser session: the browser is not running with its port, or
    /// the daemon has not reached it yet.
    NotConnected,
    Browser(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownProfile(profile) => write!(
                f,
                "no profile {profile:?} seen (it has not been started with its remote debugging port)"
            ),
            Self::NotConnected => {
                f.write_str("browser not connected (is it running with its remote debugging port?)")
            }
            Self::Browser(message) => f.write_str(message),
        }
    }
}

impl From<anyhow::Error> for Error {
    fn from(error: anyhow::Error) -> Self {
        Self::Browser(format!("{error:#}"))
    }
}

/// A launcher query, and the profile whose browser it was typed in.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
pub struct LauncherQuery {
    pub profile: String,
    pub query: String,
}

/// Every profile the daemon serves, by name — found at run time, as the
/// Waterfox wrapper records a port for each profile it starts — and the
/// launcher queries of all of them, for whoever listens (Varlink
/// `WatchLauncher`, the D-Bus `LauncherQuery` signal, the launcher command).
pub struct Profiles {
    cores: RwLock<BTreeMap<String, Arc<Core>>>,
    /// How to start a profile's browser that is not running (`Open`): the
    /// command, to which `-P <profile>` (unless `default`) and `--headless`
    /// are appended. Empty: `Open` on a closed profile fails.
    browser: Vec<String>,
    pub launcher: broadcast::Sender<LauncherQuery>,
    /// Each profile as it is first seen (the D-Bus side adds its object).
    pub added: broadcast::Sender<Arc<Core>>,
}

impl Profiles {
    pub fn new(browser: Vec<String>) -> Arc<Self> {
        Arc::new(Self {
            cores: RwLock::new(BTreeMap::new()),
            browser,
            launcher: broadcast::channel(16).0,
            added: broadcast::channel(16).0,
        })
    }

    pub fn get(&self, profile: &str) -> Result<Arc<Core>, Error> {
        self.cores
            .read()
            .expect("profiles lock")
            .get(profile)
            .cloned()
            .ok_or_else(|| Error::UnknownProfile(profile.to_owned()))
    }

    /// Every profile seen so far, by name.
    pub fn all(&self) -> Vec<Arc<Core>> {
        self.cores
            .read()
            .expect("profiles lock")
            .values()
            .cloned()
            .collect()
    }

    async fn connected(&self, profile: &str) -> Option<Arc<Core>> {
        let core = self.get(profile).ok()?;
        core.connected().await.then_some(core)
    }

    /// Open a URL in the profile's browser. A profile whose browser is not
    /// running is started first — headless if asked; `headless` means
    /// nothing to a browser already up — and the URL takes its first tab.
    pub async fn open(&self, profile: &str, url: &str, headless: bool) -> Result<String, Error> {
        if let Some(core) = self.connected(profile).await {
            return core.open(url).await;
        }
        let Some((program, args)) = self.browser.split_first() else {
            return Err(Error::NotConnected);
        };
        let mut command = tokio::process::Command::new(program);
        command.args(args);
        if profile != "default" {
            command.args(["-P", profile]);
        }
        if headless {
            command.arg("--headless");
        }
        command
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null());
        // Not awaited: the browser outlives this call (and, in its own
        // scope, this daemon).
        command
            .spawn()
            .map_err(|e| Error::Browser(format!("starting {program}: {e}")))?;
        // The wrapper records the port, discovery adopts the profile, its
        // session connects: wait for that, as long as a cold start takes.
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(90);
        loop {
            if let Some(core) = self.connected(profile).await {
                return core.open_in_first_tab(url).await;
            }
            if tokio::time::Instant::now() > deadline {
                return Err(Error::Browser(format!(
                    "started {profile:?}, but its browser never answered (does the profile exist?)"
                )));
            }
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        }
    }

    /// The profile's core, and whether this call is the one that added it.
    pub fn adopt(&self, profile: &str) -> (Arc<Core>, bool) {
        let mut cores = self.cores.write().expect("profiles lock");
        if let Some(core) = cores.get(profile) {
            return (core.clone(), false);
        }
        let core = Core::new(profile);
        cores.insert(profile.to_owned(), core.clone());
        drop(cores);
        let _ = self.added.send(core.clone());
        (core, true)
    }
}

/// One profile's browser.
pub struct Core {
    pub name: String,
    session: Mutex<Option<Arc<Bidi>>>,
}

impl Core {
    pub fn new(name: &str) -> Arc<Self> {
        Arc::new(Self {
            name: name.to_owned(),
            session: Mutex::new(None),
        })
    }

    pub async fn connected(&self) -> bool {
        self.session.lock().await.is_some()
    }

    pub async fn set_session(&self, session: Option<Arc<Bidi>>) {
        *self.session.lock().await = session;
    }

    async fn bidi(&self) -> Result<Arc<Bidi>, Error> {
        self.session.lock().await.clone().ok_or(Error::NotConnected)
    }

    pub async fn tabs(&self) -> Result<Vec<Tab>, Error> {
        let bidi = self.bidi().await?;
        let tree = bidi
            .call("browsingContext.getTree", json!({"maxDepth": 0}))
            .await?;
        let mut tabs = Vec::new();
        for context in tree["contexts"].as_array().into_iter().flatten() {
            let id = context["context"].as_str().unwrap_or_default().to_owned();
            let title = bidi
                .call(
                    "script.evaluate",
                    json!({"expression": "document.title", "target": {"context": id}, "awaitPromise": false}),
                )
                .await
                .ok()
                .and_then(|reply| reply["result"]["value"].as_str().map(str::to_owned))
                .unwrap_or_default();
            tabs.push(Tab {
                context: id,
                url: context["url"].as_str().unwrap_or_default().to_owned(),
                title,
            });
        }
        Ok(tabs)
    }

    /// The page's HTML, or with `xpath` the outer HTML of every node it
    /// selects (text and attribute nodes as their text), in document order.
    pub async fn page_html(&self, context: &str, xpath: Option<&str>) -> Result<PageHtml, Error> {
        let select = match xpath {
            None => "[document.documentElement.outerHTML]".to_owned(),
            Some(xpath) => format!(
                "(() => {{ const r = document.evaluate({}, document, null, \
                 XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null); const out = []; \
                 for (let i = 0; i < r.snapshotLength; i++) {{ const n = r.snapshotItem(i); \
                 out.push(n.outerHTML !== undefined ? n.outerHTML : n.textContent); }} \
                 return out; }})()",
                serde_json::to_string(xpath).unwrap_or_default()
            ),
        };
        let expression = format!(
            "JSON.stringify({{title: document.title, url: location.href, nodes: {select}}})"
        );
        let reply = self
            .bidi()
            .await?
            .call(
                "script.evaluate",
                json!({"expression": expression, "target": {"context": context}, "awaitPromise": false}),
            )
            .await?;
        if reply["type"] == "exception" {
            let why = reply["exceptionDetails"]["text"]
                .as_str()
                .unwrap_or("the page refused");
            return Err(Error::Browser(format!("XPath failed: {why}")));
        }
        let page: serde_json::Value = reply["result"]["value"]
            .as_str()
            .and_then(|raw| serde_json::from_str(raw).ok())
            .ok_or_else(|| Error::Browser("the page did not answer".into()))?;
        let nodes: Vec<String> = page["nodes"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|n| n.as_str().map(str::to_owned))
            .collect();
        Ok(PageHtml {
            title: page["title"].as_str().unwrap_or_default().to_owned(),
            url: page["url"].as_str().unwrap_or_default().to_owned(),
            count: nodes.len(),
            html: nodes.join("\n"),
        })
    }

    pub async fn focus(&self, context: &str) -> Result<(), Error> {
        self.bidi()
            .await?
            .call("browsingContext.activate", json!({"context": context}))
            .await?;
        Ok(())
    }

    /// A freshly started browser: the URL replaces its start tab. Opened in
    /// a new tab and the start tab closed, not navigated in place: the start
    /// page is privileged, and the browser refuses some navigations from it.
    pub async fn open_in_first_tab(&self, url: &str) -> Result<String, Error> {
        let start = self.tabs().await?;
        let context = self.open(url).await?;
        let bidi = self.bidi().await?;
        for tab in start {
            let _ = bidi
                .call("browsingContext.close", json!({"context": tab.context}))
                .await;
        }
        Ok(context)
    }

    pub async fn open(&self, url: &str) -> Result<String, Error> {
        let bidi = self.bidi().await?;
        let created = bidi
            .call("browsingContext.create", json!({"type": "tab"}))
            .await?;
        let context = created["context"].as_str().unwrap_or_default().to_owned();
        bidi.call(
            "browsingContext.navigate",
            json!({"context": context, "url": url, "wait": "none"}),
        )
        .await?;
        bidi.call("browsingContext.activate", json!({"context": context}))
            .await?;
        Ok(context)
    }
}
