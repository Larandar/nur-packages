//! A minimal HTTP/1.1 client for the backends the MCP side lends out: the
//! search door (searchwala-calf, unix socket) and blocky (loopback TCP).
use anyhow::{Context, Result};
use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper_util::rt::TokioIo;
use serde_json::Value;
use std::path::PathBuf;

#[derive(Clone, Debug)]
pub enum Endpoint {
    Unix(PathBuf),
    /// `host:port`, loopback in practice.
    Tcp(String),
}

impl Endpoint {
    /// `http://host:port` (blocky) or a socket path (the calf).
    pub fn parse(raw: &str) -> Self {
        raw.strip_prefix("http://").map_or_else(
            || Self::Unix(PathBuf::from(raw)),
            |authority| Self::Tcp(authority.trim_end_matches('/').to_owned()),
        )
    }
}

/// One request on a fresh connection; JSON body in, status and body out.
pub async fn request(
    endpoint: &Endpoint,
    method: &str,
    path: &str,
    body: Option<&Value>,
) -> Result<(u16, Bytes)> {
    let builder = hyper::Request::builder()
        .method(method)
        .uri(path)
        .header("host", "localhost");
    let request = match body {
        Some(body) => builder
            .header("content-type", "application/json")
            .body(Full::new(Bytes::from(serde_json::to_vec(body)?)))?,
        None => builder.body(Full::new(Bytes::new()))?,
    };
    let response = match endpoint {
        Endpoint::Unix(path) => {
            let stream = tokio::net::UnixStream::connect(path)
                .await
                .with_context(|| format!("{} not reachable", path.display()))?;
            let (mut sender, connection) =
                hyper::client::conn::http1::handshake(TokioIo::new(stream)).await?;
            tokio::spawn(connection);
            sender.send_request(request).await?
        }
        Endpoint::Tcp(authority) => {
            let stream = tokio::net::TcpStream::connect(authority)
                .await
                .with_context(|| format!("{authority} not reachable"))?;
            let (mut sender, connection) =
                hyper::client::conn::http1::handshake(TokioIo::new(stream)).await?;
            tokio::spawn(connection);
            sender.send_request(request).await?
        }
    };
    let status = response.status().as_u16();
    let body = response.into_body().collect().await?.to_bytes();
    Ok((status, body))
}

/// A request whose answer must be JSON and a 2xx.
pub async fn json(
    endpoint: &Endpoint,
    method: &str,
    path: &str,
    body: Option<&Value>,
) -> Result<Value> {
    let (status, bytes) = request(endpoint, method, path, body).await?;
    if !(200..300).contains(&status) {
        anyhow::bail!(
            "{method} {path}: HTTP {status}: {}",
            String::from_utf8_lossy(&bytes)
        );
    }
    if bytes.is_empty() {
        return Ok(Value::Null);
    }
    serde_json::from_slice(&bytes).with_context(|| format!("{method} {path}: not JSON"))
}

/// A request answered in NDJSON, one object per line tagged by `type`,
/// collected to its end: the `result` line's `response`, or the `error`
/// line's message. The search door streams its stages this way; a caller
/// that wants one document reads them all and keeps the last word.
pub async fn ndjson_result(endpoint: &Endpoint, method: &str, path: &str) -> Result<Value> {
    let (status, bytes) = request(endpoint, method, path, None).await?;
    if !(200..300).contains(&status) {
        anyhow::bail!(
            "{method} {path}: HTTP {status}: {}",
            String::from_utf8_lossy(&bytes)
        );
    }
    let text =
        std::str::from_utf8(&bytes).with_context(|| format!("{method} {path}: not UTF-8"))?;
    for line in text.lines().rev().filter(|line| !line.trim().is_empty()) {
        let value: Value =
            serde_json::from_str(line).with_context(|| format!("{method} {path}: not NDJSON"))?;
        match value["type"].as_str() {
            Some("result") => return Ok(value["response"].clone()),
            Some("error") => anyhow::bail!(
                "{method} {path}: {}",
                value["error"].as_str().unwrap_or("error")
            ),
            _ => {}
        }
    }
    anyhow::bail!("{method} {path}: the stream ended without a result")
}
