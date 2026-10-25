//! The MCP transport: an agent's view of the user's browser profiles and of
//! the host's search door and resolver, each profile cut to its own policy.
//! Served as streamable HTTP on `mcp.sock` beside the Varlink socket, and
//! bridged to stdio by `waterfox-remote mcp` for clients that only launch
//! commands. A profile the policy does not name is invisible here.
//!
//! READS ARE RESOURCES, AND TOOLS TOO. Every read is a resource, for clients
//! that attach context, and the same read is a tool (`tabs`, `read_page`),
//! for clients that lazy-load tool schemas and only call:
//!
//! The profile is the URI's user part, `default` when there is none:
//!
//! - `browser://[profile@]tabs` — the tabs (JSON);
//! - `browser://[profile@]tabs/<context>` — a page, parsed by the search
//!   door's SearchWala extractor: `?format=markdown` (default), `text`, or
//!   `json` (text, Markdown and the page's metadata);
//! - `browser://[profile@]tabs/<context>/<XPath>` — only what the XPath
//!   selects (percent-encode what a URI cannot carry), converted as it is;
//! - `dns://[profile@]blocking` — the resolver's blocking state (JSON).
//!
//! Tools: `tabs`, `read_page`, `focus`, `open` (the browser), `search` (the
//! door), `dns_query`, `dns_blocking`, `dns_refresh` (the resolver); each
//! takes an optional `profile` and answers under that profile's policy.
//!
//! THE POLICY IS NIX'S, NOT THE BROWSER'S. It comes from a read-only file
//! (`--mcp-policy`), never from the browser being restricted: a capability
//! it does not list is not offered at all, as tool or resource (`tabs` and
//! `read_page` gate both, `dns_status` the resolver's resource), and every page a call
//! would touch is checked against its site rules before BiDi is asked
//! anything; search results on denied sites are dropped. What it cannot
//! restrain: a process running as the same user, which can reach the
//! Varlink socket, the BiDi port, the door or blocky without MCP.
use crate::core::{Core, Error, Profiles};
use crate::http::{self, Endpoint};
use anyhow::{bail, Context, Result};
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::handler::server::wrapper::Parameters;
use rmcp::model::{
    CallToolResult, ContentBlock, Implementation, ListResourceTemplatesResult, ListResourcesResult,
    PaginatedRequestParams, ReadResourceRequestParams, ReadResourceResponse, ReadResourceResult,
    Resource, ResourceContents, ResourceTemplate, ServerCapabilities, ServerConfig,
};
use rmcp::service::RequestContext;
use rmcp::transport::streamable_http_server::session::never::NeverSessionManager;
use rmcp::transport::streamable_http_server::{StreamableHttpServerConfig, StreamableHttpService};
use rmcp::{schemars, tool, tool_handler, tool_router, ErrorData, RoleServer, ServerHandler};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;
use tokio::net::UnixListener;

/// Every capability there is; a policy names the ones it offers.
pub const CAPABILITIES: [&str; 9] = [
    "tabs",
    "read_page",
    "focus",
    "open",
    "search",
    "dns_status",
    "dns_query",
    "dns_blocking",
    "dns_refresh",
];
/// The capabilities that are tools; `dns_status` is a resource only.
const TOOLS: [&str; 8] = [
    "tabs",
    "read_page",
    "focus",
    "open",
    "search",
    "dns_query",
    "dns_blocking",
    "dns_refresh",
];

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Policy {
    pub tools: Vec<String>,
    #[serde(default)]
    pub sites: Sites,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sites {
    /// Host patterns (`*` matches any run of characters) a call may touch.
    #[serde(default = "everything")]
    pub allow: Vec<String>,
    /// Host patterns no call may touch, whatever `allow` says.
    #[serde(default)]
    pub deny: Vec<String>,
}

impl Default for Sites {
    fn default() -> Self {
        Self {
            allow: everything(),
            deny: Vec::new(),
        }
    }
}

fn everything() -> Vec<String> {
    vec!["*".into()]
}

fn glob(pattern: &str, text: &str) -> bool {
    let (p, t): (Vec<char>, Vec<char>) = (pattern.chars().collect(), text.chars().collect());
    let (mut pi, mut ti, mut star, mut mark) = (0, 0, None, 0);
    while ti < t.len() {
        if pi < p.len() && p[pi] != '*' && p[pi].eq_ignore_ascii_case(&t[ti]) {
            pi += 1;
            ti += 1;
        } else if pi < p.len() && p[pi] == '*' {
            star = Some(pi);
            mark = ti;
            pi += 1;
        } else if let Some(s) = star {
            pi = s + 1;
            mark += 1;
            ti = mark;
        } else {
            return false;
        }
    }
    p[pi..].iter().all(|&c| c == '*')
}

/// The policy file: one `Policy` per profile MCP may see; `"*"` is the
/// policy of every profile not named. Without `"*"`, an unnamed profile —
/// one created after the policy was written included — stays invisible.
#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Policies {
    pub profiles: BTreeMap<String, Policy>,
}

impl Policies {
    pub fn load(path: &Path) -> Result<Self> {
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading MCP policy {}", path.display()))?;
        let policies: Self = serde_json::from_str(&text)
            .with_context(|| format!("parsing MCP policy {}", path.display()))?;
        for (profile, policy) in &policies.profiles {
            for tool in &policy.tools {
                if !CAPABILITIES.contains(&tool.as_str()) {
                    bail!(
                        "MCP policy for {profile:?} names unknown capability {tool:?} (known: {CAPABILITIES:?})"
                    );
                }
            }
        }
        Ok(policies)
    }

    fn offered_anywhere(&self, capability: &str) -> bool {
        self.profiles.values().any(|p| p.offers(capability))
    }

    pub fn of(&self, profile: &str) -> Option<&Policy> {
        self.profiles
            .get(profile)
            .or_else(|| self.profiles.get("*"))
    }
}

impl Policy {
    pub fn offers(&self, capability: &str) -> bool {
        self.tools.iter().any(|t| t == capability)
    }

    /// The page's host against the site rules; a URL without a host
    /// (about:, data:, file:) only passes an allow of exactly `*`.
    pub fn site_allowed(&self, raw: &str) -> bool {
        let host = url::Url::parse(raw)
            .ok()
            .and_then(|parsed| parsed.host_str().map(str::to_owned));
        let Some(host) = host else {
            return self.sites.allow.iter().any(|p| p == "*")
                && !self.sites.deny.iter().any(|p| p == "*");
        };
        self.sites.allow.iter().any(|p| glob(p, &host))
            && !self.sites.deny.iter().any(|p| glob(p, &host))
    }
}

/// What the profile's MCP can reach besides the browser.
#[derive(Clone, Debug, Default)]
pub struct Backends {
    /// The search door (searchwala-calf): `/search`, and `/extract` for
    /// parsing pages. Without it, pages come back as plain text only.
    pub search: Option<Endpoint>,
    /// blocky's HTTP API.
    pub blocky: Option<Endpoint>,
}

/// A parsed `browser://` or `dns://` resource URI.
#[derive(Debug, PartialEq, Eq)]
pub enum Target {
    Tabs,
    Page {
        context: String,
        xpath: Option<String>,
        format: String,
    },
    Blocking,
}

fn percent_decode(raw: &str) -> String {
    url::form_urlencoded::parse(format!("x={}", raw.replace('+', "%2B")).as_bytes())
        .next()
        .map(|(_, v)| v.into_owned())
        .unwrap_or_default()
}

/// `browser://[profile@]tabs[/<context>[/<XPath>]][?format=…]` or
/// `dns://[profile@]blocking`: the profile (`default` when the URI names
/// none) and what is asked of it.
pub fn parse_uri(uri: &str) -> Result<(String, Target), String> {
    let (scheme, rest) = uri.split_once("://").ok_or("not a resource URI")?;
    let (rest, query) = rest.split_once('?').unwrap_or((rest, ""));
    let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
    let (profile, host) = match authority.split_once('@') {
        Some((profile, host)) => (percent_decode(profile), host),
        None => ("default".to_owned(), authority),
    };
    if profile.is_empty() {
        return Err("empty profile".into());
    }
    let format = url::form_urlencoded::parse(query.as_bytes())
        .find(|(k, _)| k == "format")
        .map_or_else(|| "markdown".to_owned(), |(_, v)| v.into_owned());
    if !["markdown", "text", "json"].contains(&format.as_str()) {
        return Err(format!(
            "format {format:?}: expected markdown, text or json"
        ));
    }
    let target = match (scheme, host, path) {
        ("dns", "blocking", "") => Target::Blocking,
        ("browser", "tabs", "") => Target::Tabs,
        ("browser", "tabs", rest) => {
            let (context, xpath) = match rest.split_once('/') {
                // The XPath is everything after the context, its own leading
                // slash included: `…/tabs/<context>//article` is `//article`.
                Some((context, xpath)) => (context, Some(percent_decode(&format!("/{xpath}")))),
                None => (rest, None),
            };
            if context.is_empty() {
                return Err("empty tab context".into());
            }
            Target::Page {
                context: percent_decode(context),
                xpath,
                format,
            }
        }
        _ => return Err("unknown resource".into()),
    };
    Ok((profile, target))
}

/// The URI's user part: none for `default`.
fn authority(profile: &str, host: &str) -> String {
    if profile == "default" {
        host.to_owned()
    } else {
        format!("{profile}@{host}")
    }
}

#[derive(Clone)]
pub struct Browser {
    profiles: Arc<Profiles>,
    policies: Arc<Policies>,
    backends: Backends,
    tool_router: ToolRouter<Self>,
}

/// The `profile` argument every tool takes.
fn profile_or_default(profile: Option<String>) -> String {
    profile.unwrap_or_else(|| "default".into())
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct ProfileArgs {
    /// The browser profile (default: `default`); its policy applies.
    pub profile: Option<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct ContextArgs {
    /// The browser profile (default: `default`); its policy applies.
    pub profile: Option<String>,
    /// A tab's context id, from `tabs`.
    pub context: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct ReadArgs {
    /// The browser profile (default: `default`); its policy applies.
    pub profile: Option<String>,
    /// A tab's context id, from `tabs`.
    pub context: String,
    /// Only what this XPath selects (e.g. `//article`, `//table[1]`).
    pub xpath: Option<String>,
    /// markdown (default), text, or json (text, Markdown and metadata).
    pub format: Option<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct OpenArgs {
    /// The browser profile (default: `default`); its policy applies.
    pub profile: Option<String>,
    pub url: String,
    /// If the profile's browser is not running, start it headless. Ignored
    /// by a browser already up.
    pub headless: Option<bool>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct SearchArgs {
    /// The browser profile (default: `default`); its policy applies.
    pub profile: Option<String>,
    pub query: String,
    /// fast, deep, study or academic; the door picks when omitted.
    pub mode: Option<String>,
    pub max_results: Option<usize>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct DnsQueryArgs {
    /// The browser profile (default: `default`); its policy applies.
    pub profile: Option<String>,
    pub name: String,
    /// Record type (A, AAAA, MX, TXT, …); A when omitted.
    #[serde(rename = "type")]
    pub record_type: Option<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
pub struct DnsBlockingArgs {
    /// The browser profile (default: `default`); its policy applies.
    pub profile: Option<String>,
    /// true: block again; false: pause blocking.
    pub enabled: bool,
    /// While paused, how long (`5m`, `1h`); until re-enabled when omitted.
    pub duration: Option<String>,
}

fn text(body: impl Into<String>) -> CallToolResult {
    CallToolResult::success(vec![ContentBlock::text(body)])
}

fn refused(why: impl Into<String>) -> CallToolResult {
    CallToolResult::error(vec![ContentBlock::text(why)])
}

fn browser_error(error: &Error) -> CallToolResult {
    refused(error.to_string())
}

fn not_found(why: impl Into<String>) -> ErrorData {
    ErrorData::resource_not_found(why.into(), None)
}

#[tool_router]
impl Browser {
    pub fn new(profiles: Arc<Profiles>, policies: Policies, backends: Backends) -> Self {
        let mut tool_router = Self::tool_router();
        for tool in TOOLS {
            let reachable = match tool {
                "search" => backends.search.is_some(),
                "dns_query" | "dns_blocking" | "dns_refresh" => backends.blocky.is_some(),
                _ => true,
            };
            if !policies.offered_anywhere(tool) || !reachable {
                tool_router.remove_route(tool);
            }
        }
        Self {
            profiles,
            policies: Arc::new(policies),
            backends,
            tool_router,
        }
    }

    /// The profile's browser and policy, if MCP sees that profile and its
    /// policy offers `capability`.
    fn scope(&self, profile: &str, capability: &str) -> Result<(Arc<Core>, &Policy), String> {
        let policy = self
            .policies
            .of(profile)
            .filter(|policy| policy.offers(capability))
            .ok_or_else(|| {
                format!("{capability} is outside the MCP policy of profile {profile:?}")
            })?;
        let core = self.profiles.get(profile).map_err(|e| e.to_string())?;
        Ok((core, policy))
    }

    /// The tab's URL, if the policy lets a call touch it.
    async fn permitted(core: &Core, policy: &Policy, context: &str) -> Result<String, String> {
        let tabs = core.tabs().await.map_err(|e| e.to_string())?;
        let tab = tabs
            .into_iter()
            .find(|tab| tab.context == context)
            .ok_or_else(|| format!("no tab {context}"))?;
        if policy.site_allowed(&tab.url) {
            Ok(tab.url)
        } else {
            Err("this tab's site is outside the MCP policy".into())
        }
    }

    #[tool(
        description = "List a profile's tabs (context, url, title, resource uri). Tabs on sites outside the policy are left out. Same as the browser://[profile@]tabs resource."
    )]
    async fn tabs(
        &self,
        Parameters(ProfileArgs { profile }): Parameters<ProfileArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        let profile = profile_or_default(profile);
        Ok(match self.read_tabs(&profile).await {
            Ok(tabs) => text(tabs),
            Err(e) => refused(e.message.to_string()),
        })
    }

    #[tool(
        description = "Read a tab, parsed by the search door: markdown (default), text, or json; optionally only what an XPath selects. Same as the browser://[profile@]tabs/<context>[/<XPath>] resource."
    )]
    async fn read_page(
        &self,
        Parameters(ReadArgs {
            profile,
            context,
            xpath,
            format,
        }): Parameters<ReadArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        let format = format.unwrap_or_else(|| "markdown".into());
        if !["markdown", "text", "json"].contains(&format.as_str()) {
            return Ok(refused(format!(
                "format {format:?}: expected markdown, text or json"
            )));
        }
        let profile = profile_or_default(profile);
        Ok(
            match self
                .page(&profile, &context, xpath.as_deref(), &format)
                .await
            {
                Ok((body, _)) => text(body),
                Err(e) => refused(e.message.to_string()),
            },
        )
    }

    #[tool(description = "Bring a tab to the front.")]
    async fn focus(
        &self,
        Parameters(ContextArgs { profile, context }): Parameters<ContextArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        let (core, policy) = match self.scope(&profile_or_default(profile), "focus") {
            Ok(scope) => scope,
            Err(why) => return Ok(refused(why)),
        };
        if let Err(why) = Self::permitted(&core, policy, &context).await {
            return Ok(refused(why));
        }
        Ok(match core.focus(&context).await {
            Ok(()) => text("focused"),
            Err(e) => browser_error(&e),
        })
    }

    #[tool(
        description = "Open a URL in a new tab, brought to the front; returns its context. A profile whose browser is not running is started first (headless if asked) and the URL takes its start tab."
    )]
    async fn open(
        &self,
        Parameters(OpenArgs {
            profile,
            url,
            headless,
        }): Parameters<OpenArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        let profile = profile_or_default(profile);
        // Not `scope`: the profile may not be running (or seen) yet.
        let Some(policy) = self.policies.of(&profile).filter(|p| p.offers("open")) else {
            return Ok(refused(format!(
                "open is outside the MCP policy of profile {profile:?}"
            )));
        };
        if !policy.site_allowed(&url) {
            return Ok(refused("this site is outside the MCP policy"));
        }
        Ok(
            match self
                .profiles
                .open(&profile, &url, headless.unwrap_or(false))
                .await
            {
                Ok(context) => text(context),
                Err(e) => browser_error(&e),
            },
        )
    }

    #[tool(
        description = "Search the web through the host's search door (SearchWala: many engines, consensus ranking). Results on sites outside the profile's policy are left out."
    )]
    async fn search(
        &self,
        Parameters(SearchArgs {
            profile,
            query,
            mode,
            max_results,
        }): Parameters<SearchArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        let (_, policy) = match self.scope(&profile_or_default(profile), "search") {
            Ok(scope) => scope,
            Err(why) => return Ok(refused(why)),
        };
        let Some(door) = &self.backends.search else {
            return Ok(refused("no search door configured"));
        };
        let mut path = format!(
            "/search?q={}",
            url::form_urlencoded::byte_serialize(query.as_bytes()).collect::<String>()
        );
        if let Some(mode) = mode {
            path.push_str(&format!(
                "&mode={}",
                url::form_urlencoded::byte_serialize(mode.as_bytes()).collect::<String>()
            ));
        }
        if let Some(n) = max_results {
            path.push_str(&format!("&max_results={n}"));
        }
        let mut answer = match http::ndjson_result(door, "GET", &path).await {
            Ok(answer) => answer,
            Err(e) => return Ok(refused(format!("search door: {e:#}"))),
        };
        if let Some(results) = answer.get_mut("results").and_then(Value::as_array_mut) {
            results.retain(|r| policy.site_allowed(r["url"].as_str().unwrap_or_default()));
        }
        Ok(text(answer.to_string()))
    }

    #[tool(
        description = "Resolve a name through the host's resolver (blocky): the answer, and whether and why it was blocked."
    )]
    async fn dns_query(
        &self,
        Parameters(DnsQueryArgs {
            profile,
            name,
            record_type,
        }): Parameters<DnsQueryArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        let blocky = match self.blocky(profile, "dns_query") {
            Ok(blocky) => blocky,
            Err(refusal) => return Ok(refusal),
        };
        let body = json!({"query": name, "type": record_type.unwrap_or_else(|| "A".into())});
        Ok(
            match http::json(blocky, "POST", "/api/query", Some(&body)).await {
                Ok(answer) => text(answer.to_string()),
                Err(e) => refused(format!("resolver: {e:#}")),
            },
        )
    }

    #[tool(
        description = "Pause or resume the resolver's blocking (all groups), optionally for a duration."
    )]
    async fn dns_blocking(
        &self,
        Parameters(DnsBlockingArgs {
            profile,
            enabled,
            duration,
        }): Parameters<DnsBlockingArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        let blocky = match self.blocky(profile, "dns_blocking") {
            Ok(blocky) => blocky,
            Err(refusal) => return Ok(refusal),
        };
        let path = if enabled {
            "/api/blocking/enable".to_owned()
        } else {
            match duration {
                Some(d) => format!(
                    "/api/blocking/disable?duration={}",
                    url::form_urlencoded::byte_serialize(d.as_bytes()).collect::<String>()
                ),
                None => "/api/blocking/disable".to_owned(),
            }
        };
        if let Err(e) = http::json(blocky, "GET", &path, None).await {
            return Ok(refused(format!("resolver: {e:#}")));
        }
        Ok(
            match http::json(blocky, "GET", "/api/blocking/status", None).await {
                Ok(status) => text(status.to_string()),
                Err(e) => refused(format!("resolver: {e:#}")),
            },
        )
    }

    #[tool(description = "Reload the resolver's blocklists and flush its cache.")]
    async fn dns_refresh(
        &self,
        Parameters(ProfileArgs { profile }): Parameters<ProfileArgs>,
    ) -> Result<CallToolResult, ErrorData> {
        let blocky = match self.blocky(profile, "dns_refresh") {
            Ok(blocky) => blocky,
            Err(refusal) => return Ok(refusal),
        };
        for path in ["/api/lists/refresh", "/api/cache/flush"] {
            if let Err(e) = http::json(blocky, "POST", path, None).await {
                return Ok(refused(format!("resolver: {e:#}")));
            }
        }
        Ok(text("blocklists reloaded, cache flushed"))
    }
}

impl Browser {
    /// blocky, if the profile's policy offers `capability` and one is set.
    fn blocky(
        &self,
        profile: Option<String>,
        capability: &str,
    ) -> Result<&Endpoint, CallToolResult> {
        if let Err(why) = self.scope(&profile_or_default(profile), capability) {
            return Err(refused(why));
        }
        self.backends
            .blocky
            .as_ref()
            .ok_or_else(|| refused("no resolver configured"))
    }

    async fn read_tabs(&self, profile: &str) -> Result<String, ErrorData> {
        let (core, policy) = self.scope(profile, "tabs").map_err(not_found)?;
        let tabs = core.tabs().await.map_err(|e| not_found(e.to_string()))?;
        let shown: Vec<Value> = tabs
            .into_iter()
            .filter(|tab| policy.site_allowed(&tab.url))
            .map(|tab| {
                let uri = format!("browser://{}/{}", authority(profile, "tabs"), tab.context);
                json!({"context": tab.context, "url": tab.url, "title": tab.title, "uri": uri})
            })
            .collect();
        Ok(Value::Array(shown).to_string())
    }

    /// The page (or what the XPath selects), parsed by the search door when
    /// there is one; plain text otherwise.
    async fn page(
        &self,
        profile: &str,
        context: &str,
        xpath: Option<&str>,
        format: &str,
    ) -> Result<(String, &'static str), ErrorData> {
        let (core, policy) = self.scope(profile, "read_page").map_err(not_found)?;
        Self::permitted(&core, policy, context)
            .await
            .map_err(not_found)?;
        let page = core
            .page_html(context, xpath)
            .await
            .map_err(|e| not_found(e.to_string()))?;
        // The page may have navigated between the check and the read.
        if !policy.site_allowed(&page.url) {
            return Err(not_found("this tab's site is outside the MCP policy"));
        }
        if xpath.is_some() && page.count == 0 {
            return Err(not_found("the XPath selected nothing"));
        }
        let mime = match format {
            "json" => "application/json",
            "markdown" => "text/markdown",
            _ => "text/plain",
        };
        let Some(door) = &self.backends.search else {
            if format != "text" {
                return Err(not_found(
                    "no search door configured: only ?format=text is available",
                ));
            }
            return Ok((strip_tags(&page.html), "text/plain"));
        };
        let request = json!({
            "html": page.html,
            "url": page.url,
            "format": format,
            "fragment": xpath.is_some(),
        });
        let mut parsed = http::json(door, "POST", "/extract", Some(&request))
            .await
            .map_err(|e| not_found(format!("search door: {e:#}")))?;
        if format == "json" {
            if parsed["title"].as_str().is_none_or(str::is_empty) {
                parsed["title"] = json!(page.title);
            }
            parsed["nodes"] = json!(page.count);
            return Ok((parsed.to_string(), mime));
        }
        let content = parsed["content"].as_str().unwrap_or_default();
        let title = if page.title.is_empty() {
            parsed["title"].as_str().unwrap_or_default().to_owned()
        } else {
            page.title.clone()
        };
        let body = if format == "markdown" && xpath.is_none() && !title.is_empty() {
            // The source line names a fetchable page; a data: URL is the
            // page itself and would repeat it.
            if page.url.starts_with("http") {
                format!("# {title}\n\n<{}>\n\n{content}", page.url)
            } else {
                format!("# {title}\n\n{content}")
            }
        } else {
            content.to_owned()
        };
        Ok((body, mime))
    }
}

/// Text of HTML without a parser: tags dropped, whitespace collapsed. Only
/// for a daemon without a search door.
fn strip_tags(html: &str) -> String {
    let html = html.replace('<', " <");
    let mut out = String::with_capacity(html.len() / 2);
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                out.push(' ');
            }
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Browser {
    fn get_info(&self) -> ServerConfig {
        let profiles: Vec<&str> = self.policies.profiles.keys().map(String::as_str).collect();
        let profiles = if profiles.contains(&"*") {
            vec!["every profile, as each starts"]
        } else {
            profiles
        };
        ServerConfig::new(
            ServerCapabilities::builder()
                .enable_tools()
                .enable_resources()
                .build(),
        )
        .with_server_info(Implementation::new(
            "waterfox-remote",
            env!("CARGO_PKG_VERSION"),
        ))
        .with_instructions(format!(
            "The user's Waterfox profiles ({}) over WebDriver BiDi, with the host's search \
             door and resolver. Read pages as resources: browser://[profile@]tabs, then \
             browser://[profile@]tabs/<context>[/<XPath>]?format=markdown|text|json (no \
             profile@ means `default`). Tools take an optional `profile`. Each profile \
             reaches only the capabilities and sites its own policy allows.",
            profiles.join(", ")
        ))
    }

    async fn list_resources(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, ErrorData> {
        let mut resources = Vec::new();
        for core in self.profiles.all() {
            let profile = &core.name;
            let Some(policy) = self.policies.of(profile) else {
                continue;
            };
            if policy.offers("tabs") {
                resources.push(
                    Resource::new(
                        format!("browser://{}", authority(profile, "tabs")),
                        format!("{profile} tabs"),
                    )
                    .with_description(
                        "The profile's tabs (context, url, title, uri); denied sites left out.",
                    )
                    .with_mime_type("application/json"),
                );
            }
            if policy.offers("dns_status") && self.backends.blocky.is_some() {
                resources.push(
                    Resource::new(
                        format!("dns://{}", authority(profile, "blocking")),
                        format!("{profile} dns-blocking"),
                    )
                    .with_description("The resolver's blocking state.")
                    .with_mime_type("application/json"),
                );
            }
        }
        Ok(ListResourcesResult::with_all_items(resources))
    }

    async fn list_resource_templates(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourceTemplatesResult, ErrorData> {
        if !self.policies.offered_anywhere("read_page") {
            return Ok(ListResourceTemplatesResult::with_all_items(Vec::new()));
        }
        Ok(ListResourceTemplatesResult::with_all_items(vec![
            ResourceTemplate::new("browser://{profile}@tabs/{context}{?format}", "page")
                .with_description(
                    "A tab's page, parsed: markdown (default), text, or json with metadata. \
                     Drop `{profile}@` for the default profile.",
                )
                .with_mime_type("text/markdown"),
            ResourceTemplate::new(
                "browser://{profile}@tabs/{context}{+xpath}{?format}",
                "page-xpath",
            )
            .with_description(
                "Only what an XPath selects in a tab (e.g. //article, //table[1]). Drop \
                 `{profile}@` for the default profile.",
            )
            .with_mime_type("text/markdown"),
        ]))
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, ErrorData> {
        let uri = request.uri;
        let (profile, target) = parse_uri(&uri).map_err(not_found)?;
        let (body, mime) = match target {
            Target::Tabs => (self.read_tabs(&profile).await?, "application/json"),
            Target::Page {
                context,
                xpath,
                format,
            } => {
                self.page(&profile, &context, xpath.as_deref(), &format)
                    .await?
            }
            Target::Blocking => {
                self.scope(&profile, "dns_status").map_err(not_found)?;
                let blocky = self
                    .backends
                    .blocky
                    .as_ref()
                    .ok_or_else(|| not_found("no resolver configured"))?;
                let status = http::json(blocky, "GET", "/api/blocking/status", None)
                    .await
                    .map_err(|e| not_found(format!("resolver: {e:#}")))?;
                (status.to_string(), "application/json")
            }
        };
        Ok(
            ReadResourceResult::new(vec![ResourceContents::text(body, uri).with_mime_type(mime)])
                .into(),
        )
    }
}

/// Streamable HTTP, stateless and plain JSON, on the user's MCP socket.
pub async fn serve(listener: UnixListener, browser: Browser) -> Result<()> {
    let mut config = StreamableHttpServerConfig::default();
    config.legacy_session_mode = false;
    config.json_response = true;
    let service = StreamableHttpService::new(
        move || Ok(browser.clone()),
        Arc::new(NeverSessionManager::default()),
        config,
    );
    let router = axum::Router::new().nest_service("/mcp", service);
    axum::serve(listener, router).await?;
    Ok(())
}

/// stdio ⇄ the daemon's MCP socket, for clients that only launch commands:
/// each JSON-RPC line from stdin is POSTed; JSON or SSE answers go to stdout
/// one message per line. The daemon keeps no session, so neither does this.
pub async fn bridge(socket: &Path) -> Result<()> {
    use http_body_util::{BodyExt, Full};
    use hyper::body::Bytes;
    use hyper_util::rt::TokioIo;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

    let mut stdin = BufReader::new(tokio::io::stdin()).lines();
    let mut stdout = tokio::io::stdout();
    while let Some(line) = stdin.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let stream = tokio::net::UnixStream::connect(socket)
            .await
            .with_context(|| {
                format!("waterfox-remote MCP not reachable at {}", socket.display())
            })?;
        let (mut sender, connection) =
            hyper::client::conn::http1::handshake(TokioIo::new(stream)).await?;
        tokio::spawn(connection);
        let request = hyper::Request::post("/mcp")
            .header("host", "localhost")
            .header("content-type", "application/json")
            .header("accept", "application/json, text/event-stream")
            .body(Full::new(Bytes::from(line)))?;
        let response = sender.send_request(request).await?;
        let is_sse = response
            .headers()
            .get("content-type")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.starts_with("text/event-stream"));
        let status = response.status();
        let body = response.into_body().collect().await?.to_bytes();
        if status == hyper::StatusCode::ACCEPTED || body.is_empty() {
            continue; // a notification: nothing to answer
        }
        let text = String::from_utf8_lossy(&body);
        let messages: Vec<String> = if is_sse {
            text.lines()
                .filter_map(|l| l.strip_prefix("data:"))
                .map(|d| d.trim().to_owned())
                .filter(|d| !d.is_empty())
                .collect()
        } else {
            vec![text.trim().to_owned()]
        };
        for message in messages {
            stdout.write_all(message.as_bytes()).await?;
            stdout.write_all(b"\n").await?;
        }
        stdout.flush().await?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy(allow: &[&str], deny: &[&str]) -> Policy {
        Policy {
            tools: vec!["tabs".into()],
            sites: Sites {
                allow: allow.iter().map(|s| (*s).to_owned()).collect(),
                deny: deny.iter().map(|s| (*s).to_owned()).collect(),
            },
        }
    }

    #[test]
    fn deny_wins_over_allow() {
        let p = policy(&["*"], &["mail.*", "*.bank.example"]);
        assert!(p.site_allowed("https://docs.rs/zbus"));
        assert!(!p.site_allowed("https://mail.example.org/inbox"));
        assert!(!p.site_allowed("https://www.bank.example/"));
    }

    #[test]
    fn allow_list_is_exclusive() {
        let p = policy(&["*.vegr", "docs.rs"], &[]);
        assert!(p.site_allowed("https://odin.vegr/?q=x"));
        assert!(p.site_allowed("https://DOCS.rs/"));
        assert!(!p.site_allowed("https://example.org/"));
        // No host: only a bare `*` lets it through.
        assert!(!p.site_allowed("about:blank"));
        assert!(policy(&["*"], &[]).site_allowed("about:blank"));
    }

    fn page(context: &str, xpath: Option<&str>, format: &str) -> Target {
        Target::Page {
            context: context.into(),
            xpath: xpath.map(Into::into),
            format: format.into(),
        }
    }

    #[test]
    fn resource_uris() {
        let ok = |uri: &str| parse_uri(uri).unwrap();
        assert_eq!(ok("browser://tabs"), ("default".into(), Target::Tabs));
        assert_eq!(ok("browser://work@tabs"), ("work".into(), Target::Tabs));
        assert_eq!(
            ok("browser://work@tabs/c-1?format=json"),
            ("work".into(), page("c-1", None, "json"))
        );
        assert_eq!(
            ok("browser://tabs/c-1//article/p%5B2%5D"),
            (
                "default".into(),
                page("c-1", Some("//article/p[2]"), "markdown")
            )
        );
        assert_eq!(
            ok("browser://work@tabs/c-1/html/body"),
            ("work".into(), page("c-1", Some("/html/body"), "markdown"))
        );
        assert_eq!(ok("dns://blocking"), ("default".into(), Target::Blocking));
        assert_eq!(ok("dns://work@blocking"), ("work".into(), Target::Blocking));
        for bad in [
            "browser://work/tabs",
            "browser://@tabs",
            "browser://tabs/c?format=pdf",
            "file:///etc/passwd",
        ] {
            assert!(parse_uri(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn policies_load_and_fall_back_to_star() {
        let dir = std::env::temp_dir().join(format!("wr-policy-{}", std::process::id()));
        std::fs::write(
            &dir,
            r#"{"profiles": {"work": {"tools": ["tabs", "shell"]}}}"#,
        )
        .unwrap();
        assert!(Policies::load(&dir).is_err());
        std::fs::write(
            &dir,
            r#"{"profiles": {"work": {"tools": ["tabs"], "sites": {"deny": ["x"]}}, "*": {"tools": ["read_page"]}}}"#,
        )
        .unwrap();
        let policies = Policies::load(&dir).unwrap();
        std::fs::remove_file(&dir).unwrap();
        assert_eq!(policies.of("work").unwrap().sites.allow, ["*"]);
        assert!(policies.of("work").unwrap().offers("tabs"));
        assert!(policies.of("brand-new").unwrap().offers("read_page"));
        assert!(!policies.of("brand-new").unwrap().offers("tabs"));
    }
}
