//! One WebDriver BiDi connection to the browser: commands go out with an id,
//! the reader task routes each answer to its waiter and every event to the
//! event channel.
use anyhow::{anyhow, Context, Result};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot, Mutex};
use tokio_tungstenite::tungstenite::Message;

/// Requests to this host are the browser's launcher alias; they are failed
/// in the browser and never leave the machine.
pub const LAUNCHER_HOST: &str = "launcher.invalid";

type Waiters = Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value>>>>>;

pub struct Bidi {
    out: mpsc::UnboundedSender<Message>,
    pending: Waiters,
    next: AtomicU64,
    /// The socket's two halves. Dropping the session aborts both, which is
    /// what closes the WebSocket: the browser allows one session at a time,
    /// so a connection left open by a failed handshake would lock every
    /// later attempt out.
    tasks: [tokio::task::JoinHandle<()>; 2],
}

impl Drop for Bidi {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

impl Bidi {
    pub async fn connect(port: u16) -> Result<(Arc<Self>, mpsc::UnboundedReceiver<Value>)> {
        let (ws, _) = tokio_tungstenite::connect_async(format!("ws://127.0.0.1:{port}/session"))
            .await
            .context("browser's remote debugging port not answering")?;
        let (mut sink, mut stream) = ws.split();
        let (out, mut outgoing) = mpsc::unbounded_channel::<Message>();
        let (events_tx, events) = mpsc::unbounded_channel();
        let pending: Waiters = Arc::default();
        let writer = tokio::spawn(async move {
            while let Some(message) = outgoing.recv().await {
                if sink.send(message).await.is_err() {
                    break;
                }
            }
        });
        let routes = pending.clone();
        let reader = tokio::spawn(async move {
            while let Some(Ok(message)) = stream.next().await {
                let Message::Text(text) = message else {
                    continue;
                };
                let Ok(value) = serde_json::from_str::<Value>(&text) else {
                    continue;
                };
                match value["type"].as_str() {
                    Some("event") => {
                        let _ = events_tx.send(value);
                    }
                    Some("success" | "error") => {
                        let Some(id) = value["id"].as_u64() else {
                            continue;
                        };
                        if let Some(waiter) = routes.lock().await.remove(&id) {
                            let answer = if value["type"] == "success" {
                                Ok(value["result"].clone())
                            } else {
                                Err(anyhow!("{}: {}", value["error"], value["message"]))
                            };
                            let _ = waiter.send(answer);
                        }
                    }
                    _ => {}
                }
            }
            // The connection is gone: fail every waiter so callers see it.
            for (_, waiter) in routes.lock().await.drain() {
                let _ = waiter.send(Err(anyhow!("browser connection closed")));
            }
        });
        let bidi = Arc::new(Self {
            out,
            pending,
            next: AtomicU64::new(1),
            tasks: [writer, reader],
        });
        // NO DEADLINE ON THE HANDSHAKE. A browser still starting up answers
        // late, and it creates the session anyway: give up on it and that
        // session lives on with no connection, holding the browser's only
        // slot ("Maximum number of active sessions") until it exits. The
        // wait ends with the connection if the browser goes away.
        bidi.request("session.new", json!({"capabilities": {}}), None)
            .await?;
        Ok((bidi, events))
    }

    pub async fn call(&self, method: &str, params: Value) -> Result<Value> {
        self.request(method, params, Some(Duration::from_secs(10)))
            .await
    }

    async fn request(
        &self,
        method: &str,
        params: Value,
        deadline: Option<Duration>,
    ) -> Result<Value> {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(id, tx);
        let message = json!({"id": id, "method": method, "params": params});
        self.out
            .send(Message::Text(message.to_string().into()))
            .map_err(|_| anyhow!("browser connection closed"))?;
        match deadline {
            Some(deadline) => tokio::time::timeout(deadline, rx)
                .await
                .context("browser did not answer")??,
            None => rx.await.context("browser connection closed")?,
        }
    }

    /// Ask the browser to hold every request to the launcher host for us.
    pub async fn intercept_launcher(&self) -> Result<()> {
        self.call(
            "session.subscribe",
            json!({"events": ["network.beforeRequestSent"]}),
        )
        .await?;
        self.call(
            "network.addIntercept",
            json!({
                "phases": ["beforeRequestSent"],
                "urlPatterns": [{"type": "pattern", "protocol": "https", "hostname": LAUNCHER_HOST}],
            }),
        )
        .await?;
        Ok(())
    }

    /// A held launcher request: fail it in the browser, step the tab back,
    /// and return its query. Any other event is `None`.
    pub async fn take_launcher_query(&self, event: &Value) -> Option<String> {
        if event["method"] != "network.beforeRequestSent" || event["params"]["isBlocked"] != true {
            return None;
        }
        let request = &event["params"]["request"];
        let _ = self
            .call(
                "network.failRequest",
                json!({"request": request["request"]}),
            )
            .await;
        if let Some(context) = event["params"]["context"].as_str() {
            let _ = self
                .call(
                    "browsingContext.traverseHistory",
                    json!({"context": context, "delta": -1}),
                )
                .await;
        }
        Some(launcher_query(request["url"].as_str().unwrap_or_default()))
    }
}

/// The `q` parameter of a launcher URL; empty when there is none.
pub fn launcher_query(raw: &str) -> String {
    url::Url::parse(raw)
        .ok()
        .and_then(|parsed| {
            parsed
                .query_pairs()
                .find(|(key, _)| key == "q")
                .map(|(_, value)| value.into_owned())
        })
        .unwrap_or_default()
}
