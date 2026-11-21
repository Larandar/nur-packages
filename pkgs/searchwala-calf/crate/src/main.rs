//! searchwala-calf — a lite SearchWala: the search pipeline behind one route.
//!
//! Deliberately thin, deliberately ours. SearchWala's own binary ships a
//! server, a UI, modes routing, LLM wiring and databases; the estate wants
//! none of that surface. This crate imports the PIPELINE and nothing else:
//!
//! - `searchwala::search::execute_search_full` — the engines + consensus
//!   ranking + extraction pipeline;
//! - `searchwala::models` — the response types.
//!
//! `POST /extract` lends the same parsing to HTML the caller already holds
//! (see extract.rs): Markdown, text or structured JSON, nothing fetched.
//!
//! Everything above that is here: one route (`GET /search`, its stages
//! streamed as NDJSON), one transport
//! (a unix socket by default, `LISTEN_UNIX`; TCP `HOST`/`PORT` where unix
//! sockets do not fit — the darwin half), no state (`TempDb`/`HistoryDb`
//! passed as `None`), no LLM, no modes exposed beyond a `mode`/`domain`
//! passthrough for the day the start page grows a form for them.
mod extract;

use anyhow::{Context, Result};
use axum::body::Body;
use axum::extract::Query;
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use clap::Parser;
use hyper_util::rt::{TokioExecutor, TokioIo};
use searchwala::search::{execute_search_full, Progress, SearchParams};
use serde::Deserialize;
use std::convert::Infallible;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;
use tower::Service;
use tracing::Instrument;

/// The query surface, kept to what the start page can say. Anything more
/// (copilot, LLM configs) is a decision to make here, not a surface
/// inherited from upstream.
/// `q` is optional only at extraction: a schema request needs none, and a
/// search without one is refused.
#[derive(Deserialize)]
struct SearchQuery {
    q: Option<String>,
    mode: Option<String>,
    domain: Option<String>,
    max_results: Option<usize>,
}

/// `SearchQuery` as JSON Schema, by hand beside the struct it describes:
/// what `Accept: application/json` on `/search` answers.
fn query_schema() -> serde_json::Value {
    serde_json::json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "GET /search query",
        "description": "The query string of GET /search. The answer is NDJSON (application/x-ndjson): one object per line tagged by `type` (plan, engines, sources, extracted, highlight, synthesizing), then `result` with the full response, or `error`.",
        "type": "object",
        "required": ["q"],
        "additionalProperties": false,
        "properties": {
            "q": { "type": "string", "minLength": 1, "description": "What to search for." },
            "mode": {
                "type": "string",
                "description": "SearchWala focus mode; `auto` when absent.",
                "examples": ["fast", "deep", "study", "academic"]
            },
            "domain": { "type": "string", "description": "Domain hint passed to SearchWala's mode parser." },
            "max_results": { "type": "integer", "minimum": 1, "description": "Upper bound on the results returned." }
        }
    })
}

/// `Accept: application/json` answers the query's JSON Schema instead.
/// Otherwise the answer is a stream of newline-delimited JSON, one object per
/// line, tagged by `type`: the pipeline's stages as they happen (`plan`,
/// `engines`, `sources` — the ranked hits before any page is fetched —
/// `extracted`, `highlight`, `synthesizing`), then `result` with the full
/// response, or `error`. The start page draws each line as it lands, so
/// nothing waits on the slowest source; a client that wants one document
/// reads to the end and keeps the `result` line. A client that goes away
/// aborts the pipeline rather than leaving it scraping for nobody.
async fn search(headers: HeaderMap, Query(q): Query<SearchQuery>) -> Response {
    let wants_schema = headers
        .get(header::ACCEPT)
        .and_then(|accept| accept.to_str().ok())
        .is_some_and(|accept| accept.contains("application/json"));
    if wants_schema {
        return Json(query_schema()).into_response();
    }
    let Some(query) = q.q.filter(|query| !query.trim().is_empty()) else {
        return (
            StatusCode::BAD_REQUEST,
            "q is required; Accept: application/json gives the query schema\n",
        )
            .into_response();
    };

    let span = tracing::info_span!(
        "search",
        mode = q.mode.as_deref().unwrap_or("auto"),
        domain = q.domain.as_deref().unwrap_or("-"),
        // The query text never enters telemetry: it is user content.
        q_len = query.len()
    );
    let params = SearchParams {
        query,
        max_results: q.max_results,
        focus_mode: q.mode,
        domain: q.domain,
        // THE LLM PATH IS OPEN, DELIBERATELY. A System-1 evaluation per
        // result — score every source the pipeline returns before it is
        // surfaced — is envisageable for important requests; upstream's
        // BYOK `LlmConfig` is the seam it would ride. Until that decision
        // is made, the estate runs without one: an unset `CALF_LLM_*`
        // environment means `None`, never a default model.
        llm: llm_from_env(),
        enable_copilot: false,
    };

    let (lines, rx) = mpsc::channel::<Result<String, Infallible>>(64);
    tokio::spawn(
        async move {
            let (progress, mut stages) = mpsc::channel::<Progress>(32);
            let pipeline = tokio::spawn(
                async move {
                    let response = execute_search_full(params, None, None, Some(progress)).await;
                    tracing::info!(
                        sources_found = response.sources_found,
                        elapsed = response.elapsed_seconds,
                        "search complete"
                    );
                    response
                }
                .in_current_span(),
            );
            while let Some(stage) = stages.recv().await {
                if lines.send(Ok(ndjson(&stage))).await.is_err() {
                    tracing::info!("client gone; aborting the pipeline");
                    pipeline.abort();
                    return;
                }
            }
            let last = match pipeline.await {
                Ok(response) => serde_json::json!({ "type": "result", "response": response }),
                Err(err) => serde_json::json!({ "type": "error", "error": err.to_string() }),
            };
            let _ = lines.send(Ok(ndjson(&last))).await;
        }
        .instrument(span),
    );

    (
        [(header::CONTENT_TYPE, "application/x-ndjson")],
        Body::from_stream(ReceiverStream::new(rx)),
    )
        .into_response()
}

/// One NDJSON line: compact JSON never carries a raw newline.
fn ndjson(value: &impl serde::Serialize) -> String {
    let mut line = serde_json::to_string(value).unwrap_or_else(|err| {
        serde_json::json!({ "type": "error", "error": err.to_string() }).to_string()
    });
    line.push('\n');
    line
}

/// The LLM seam. `CALF_LLM_PROVIDER`, `CALF_LLM_MODEL` and `CALF_LLM_API_KEY`
/// together arm it (a System-1 evaluator needs all three to be a decision
/// rather than an accident); `CALF_LLM_BASE_URL` points it at the estate's
/// own gateway (`modron.vegr`). Absent → `None` → upstream's no-LLM path,
/// whose highlight answer is verbatim quotation and cannot hallucinate.
fn llm_from_env() -> Option<searchwala::models::LlmConfig> {
    let (provider, model, api_key) = match (
        std::env::var("CALF_LLM_PROVIDER"),
        std::env::var("CALF_LLM_MODEL"),
        std::env::var("CALF_LLM_API_KEY"),
    ) {
        (Ok(p), Ok(m), Ok(k)) if !p.is_empty() && !m.is_empty() && !k.is_empty() => (p, m, k),
        _ => return None,
    };

    Some(searchwala::models::LlmConfig {
        provider,
        api_key,
        model,
        base_url: std::env::var("CALF_LLM_BASE_URL")
            .ok()
            .filter(|s| !s.is_empty()),
        timeout_ms: std::env::var("CALF_LLM_TIMEOUT_MS")
            .ok()
            .and_then(|v| v.parse().ok()),
        max_output_tokens: std::env::var("CALF_LLM_MAX_OUTPUT_TOKENS")
            .ok()
            .and_then(|v| v.parse().ok()),
    })
}

async fn health() -> &'static str {
    "ok"
}

fn router() -> axum::Router {
    use axum::routing::{get, post};
    axum::Router::new()
        .route("/search", get(search))
        .route("/extract", post(extract::handler))
        .route("/health", get(health))
}

async fn serve_uds(path: String) -> Result<()> {
    // A stale socket from a hard kill is removed, never inherited: bind would
    // otherwise fail on the leftover inode.
    let _ = tokio::fs::remove_file(&path).await;
    let listener = tokio::net::UnixListener::bind(&path).context(format!("bind {path}"))?;

    // The edge (Caddy, another account) is the only intended client: the
    // socket is world-accessible, the mesh is the boundary.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o666)).await?;
    }

    tracing::info!("searchwala-calf listening on unix:{path}");
    let builder = Arc::new(hyper_util::server::conn::auto::Builder::new(
        TokioExecutor::new(),
    ));
    loop {
        let (stream, _) = listener.accept().await?;
        let io = TokioIo::new(stream);
        let app = router();
        let builder = builder.clone();
        // axum's Router is a tower Service; hyper wants its own trait — the
        // service_fn adapter is the documented bridge between the two.
        let svc = hyper::service::service_fn(move |req| {
            let mut app = app.clone();
            async move { app.call(req).await.map_err(anyhow::Error::from) }
        });
        tokio::spawn(async move {
            if let Err(err) = builder.serve_connection_with_upgrades(io, svc).await {
                tracing::debug!("connection error: {err}");
            }
        });
    }
}

async fn serve_tcp(host: String, port: u16) -> Result<()> {
    let listener = tokio::net::TcpListener::bind((host.as_str(), port))
        .await
        .context(format!("bind {host}:{port}"))?;
    tracing::info!("searchwala-calf listening on tcp://{host}:{port}");
    let builder = Arc::new(hyper_util::server::conn::auto::Builder::new(
        TokioExecutor::new(),
    ));
    loop {
        let (stream, _) = listener.accept().await?;
        let io = TokioIo::new(stream);
        let app = router();
        let builder = builder.clone();
        let svc = hyper::service::service_fn(move |req| {
            let mut app = app.clone();
            async move { app.call(req).await.map_err(anyhow::Error::from) }
        });
        tokio::spawn(async move {
            if let Err(err) = builder.serve_connection_with_upgrades(io, svc).await {
                tracing::debug!("connection error: {err}");
            }
        });
    }
}

/// The listener is the only CLI surface. LLM credentials are deliberately NOT
/// arguments: secrets arrive through the environment, delivered by secretspec
/// (`secretspec env` / a rendered EnvironmentFile), and a process listing can
/// read its own argv — keys on argv are a leak with a `ps`.
#[derive(clap::Parser)]
struct Args {
    /// Unix socket to serve on; empty/unset falls back to TCP.
    #[arg(long, env = "LISTEN_UNIX")]
    socket: Option<String>,
    /// TCP host for the fallback listener (darwin's shape).
    #[arg(long, env = "HOST", default_value = "127.0.0.1")]
    host: String,
    /// TCP port for the fallback listener.
    #[arg(long, env = "PORT", default_value_t = 8899)]
    port: u16,
}

#[tokio::main]
async fn main() -> Result<()> {
    // A `.env` beside a local `cargo run`; in deployment secretspec speaks
    // for the environment and there is no file to find.
    dotenvy::dotenv().ok();

    // Local logs always; OTLP spans only when a collector endpoint is set.
    // `RT-TOKIO` keeps the batch exporter off the connection tasks.
    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| "searchwala_calf=info,warn".parse().unwrap());
    let fmt_layer = tracing_subscriber::fmt::layer();
    match std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT") {
        Ok(endpoint) if !endpoint.is_empty() => {
            let exporter = opentelemetry_otlp::SpanExporter::builder()
                .with_tonic()
                .build()?;
            let provider = opentelemetry_sdk::trace::SdkTracerProvider::builder()
                .with_batch_exporter(exporter)
                .build();
            use opentelemetry::trace::TracerProvider as _;
            let otel_layer =
                tracing_opentelemetry::layer().with_tracer(provider.tracer("searchwala-calf"));
            use tracing_subscriber::prelude::*;
            tracing_subscriber::registry()
                .with(filter)
                .with(fmt_layer)
                .with(otel_layer)
                .init();
            tracing::info!(%endpoint, "OTLP trace export enabled");
        }
        _ => {
            use tracing_subscriber::prelude::*;
            tracing_subscriber::registry()
                .with(filter)
                .with(fmt_layer)
                .init();
        }
    }
    let args = Args::parse();
    match args.socket {
        Some(path) if !path.is_empty() => serve_uds(path).await,
        _ => serve_tcp(args.host, args.port).await,
    }
}
