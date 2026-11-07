//! The D-Bus transport: `ad.lar.WaterfoxRemote1` on the session bus, one
//! object per profile (added as each is first seen) at `/ad/lar/WaterfoxRemote1/<profile>`, interface
//! `ad.lar.WaterfoxRemote1`. The session bus is the user's own, so nobody
//! else can call it.
use crate::core::{Core, Error, Profiles};
use anyhow::{Context, Result};
use std::sync::Arc;
use zbus::fdo;
use zbus::object_server::SignalEmitter;

pub const NAME: &str = "ad.lar.WaterfoxRemote1";
pub const ROOT: &str = "/ad/lar/WaterfoxRemote1";

/// The profile's object path. Path elements are `[A-Za-z0-9_]`: anything
/// else (profile names may carry `-`) becomes `_` and its hex code, and `_`
/// itself is escaped the same way, so the mapping is reversible.
pub fn path(profile: &str) -> String {
    let mut element = String::new();
    for c in profile.chars() {
        if c.is_ascii_alphanumeric() {
            element.push(c);
        } else {
            element.push_str(&format!("_{:02x}", c as u32));
        }
    }
    if element.is_empty() {
        element.push('_');
    }
    format!("{ROOT}/{element}")
}

struct Remote {
    core: Arc<Core>,
    profiles: Arc<Profiles>,
}

fn failed(error: &Error) -> fdo::Error {
    fdo::Error::Failed(error.to_string())
}

#[zbus::interface(name = "ad.lar.WaterfoxRemote1")]
impl Remote {
    /// The profile this object is.
    #[zbus(property)]
    fn profile(&self) -> String {
        self.core.name.clone()
    }

    /// Every top-level tab: (context, url, title).
    async fn tabs(&self) -> fdo::Result<Vec<(String, String, String)>> {
        let tabs = self.core.tabs().await.map_err(|e| failed(&e))?;
        Ok(tabs
            .into_iter()
            .map(|tab| (tab.context, tab.url, tab.title))
            .collect())
    }

    async fn focus(&self, context: String) -> fdo::Result<()> {
        self.core.focus(&context).await.map_err(|e| failed(&e))
    }

    /// Open a URL in a new tab; returns its context. A browser not running
    /// is started first, headless if asked.
    async fn open(&self, url: String, headless: bool) -> fdo::Result<String> {
        self.profiles
            .open(&self.core.name, &url, headless)
            .await
            .map_err(|e| failed(&e))
    }

    /// A query typed behind this profile's launcher alias.
    #[zbus(signal)]
    async fn launcher_query(emitter: &SignalEmitter<'_>, query: &str) -> zbus::Result<()>;
}

/// Claim the name, serve every profile, and forward launcher queries as
/// signals from their profile's object. Keep the connection alive.
pub async fn serve(profiles: Arc<Profiles>) -> Result<zbus::Connection> {
    let mut queries = profiles.launcher.subscribe();
    let mut added = profiles.added.subscribe();
    let connection = zbus::connection::Builder::session()?
        .name(NAME)?
        .build()
        .await
        .with_context(|| format!("claiming {NAME} on the session bus"))?;
    // Profiles come and go at run time: every one seen so far gets its
    // object now, every later one as it appears.
    for core in profiles.all() {
        connection
            .object_server()
            .at(
                path(&core.name),
                Remote {
                    core,
                    profiles: profiles.clone(),
                },
            )
            .await?;
    }
    let server = connection.clone();
    let all = profiles.clone();
    tokio::spawn(async move {
        while let Ok(core) = added.recv().await {
            let _ = server
                .object_server()
                .at(
                    path(&core.name),
                    Remote {
                        core,
                        profiles: all.clone(),
                    },
                )
                .await;
        }
    });
    let bus = connection.clone();
    tokio::spawn(async move {
        loop {
            match queries.recv().await {
                Ok(launch) => {
                    if let Ok(emitter) = SignalEmitter::new(&bus, path(&launch.profile)) {
                        let _ = Remote::launcher_query(&emitter, &launch.query).await;
                    }
                }
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
            }
        }
    });
    Ok(connection)
}
