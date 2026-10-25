//! `POST /extract` — SearchWala's page parsing for HTML the caller already
//! has (waterfox-remote reads it from a tab), so nothing is fetched here.
//!
//! - a whole page (`fragment: false`): SearchWala's extractor for text and
//!   metadata (trafilatura, Readability as a second opinion, JSON-LD and
//!   hydration fallbacks); for `markdown`, Readability's article HTML
//!   converted by htmd (it keeps headings, lists, tables and links where
//!   trafilatura's own Markdown can come back flat). A page too short for
//!   Readability to call an article has no boilerplate worth stripping, so
//!   it is converted whole, chrome (head, scripts, nav, footer) skipped;
//! - a fragment (`fragment: true`, e.g. what an XPath selected): no
//!   boilerplate to strip, so the HTML is converted as it is.
use axum::Json;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Format {
    #[default]
    Markdown,
    Text,
    Json,
}

#[derive(Deserialize)]
pub struct Request {
    pub html: String,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub format: Format,
    #[serde(default)]
    pub fragment: bool,
}

#[derive(Debug, Default, Serialize)]
pub struct Metadata {
    pub published: Option<String>,
    pub language: Option<String>,
    pub page_type: Option<String>,
    pub confidence: Option<f64>,
    /// Which extractor produced the text that was kept.
    pub source: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Response {
    pub title: String,
    pub url: String,
    pub format: Format,
    /// Markdown, plain text, or (for `json`) the text, with `markdown` beside it.
    pub content: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub markdown: Option<String>,
    pub metadata: Metadata,
}

fn readability_markdown(html: &str, url: &str) -> Option<String> {
    let base = (!url.is_empty()).then_some(url);
    let mut reader = dom_smoothie::Readability::new(html, base, None).ok()?;
    let article = reader.parse().ok()?;
    let markdown = htmd::convert(&article.content).ok()?;
    let markdown = markdown.trim();
    (!markdown.is_empty()).then(|| markdown.to_owned())
}

fn whole_markdown(html: &str) -> Option<String> {
    let converter = htmd::HtmlToMarkdown::builder()
        .skip_tags(vec![
            "head", "script", "style", "noscript", "nav", "footer", "template",
        ])
        .build();
    let markdown = converter.convert(html).ok()?;
    let markdown = markdown.trim();
    (!markdown.is_empty()).then(|| markdown.to_owned())
}

fn fragment_markdown(html: &str) -> String {
    htmd::convert(html).unwrap_or_default().trim().to_owned()
}

fn fragment_text(html: &str) -> String {
    let doc = scraper::Html::parse_fragment(html);
    let text: Vec<&str> = doc.root_element().text().collect();
    text.join(" ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn extract(request: &Request) -> Response {
    let Request {
        html,
        url,
        format,
        fragment,
    } = request;
    if *fragment {
        let markdown = fragment_markdown(html);
        let text = fragment_text(html);
        return Response {
            title: String::new(),
            url: url.clone(),
            format: *format,
            content: match format {
                Format::Markdown => markdown.clone(),
                Format::Text | Format::Json => text,
            },
            markdown: (*format == Format::Json).then_some(markdown),
            metadata: Metadata::default(),
        };
    }
    let page = searchwala::extractor::extract(html, url);
    let metadata = Metadata {
        published: page.published.map(|date| date.to_rfc3339()),
        language: page.language.clone(),
        page_type: page.page_type.clone(),
        confidence: Some(page.confidence),
        source: Some(page.source.to_owned()),
    };
    // Readability's article keeps the document's structure; a page too
    // short for it goes whole; SearchWala's own text (which tried hardest to
    // find content at all) is the last resort.
    let markdown = match format {
        Format::Markdown | Format::Json => Some(
            readability_markdown(html, url)
                .or_else(|| whole_markdown(html))
                .unwrap_or_else(|| page.text.clone()),
        ),
        Format::Text => None,
    };
    Response {
        title: page.title,
        url: url.clone(),
        format: *format,
        content: match format {
            Format::Markdown => markdown.clone().unwrap_or_default(),
            Format::Text | Format::Json => page.text,
        },
        markdown: if *format == Format::Json {
            markdown
        } else {
            None
        },
        metadata,
    }
}

pub async fn handler(Json(request): Json<Request>) -> Json<Response> {
    // Parsing is CPU-bound; keep it off the async workers.
    let response = tokio::task::spawn_blocking(move || extract(&request))
        .await
        .unwrap_or_else(|_| Response {
            title: String::new(),
            url: String::new(),
            format: Format::Text,
            content: String::new(),
            markdown: None,
            metadata: Metadata::default(),
        });
    Json(response)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fragments_convert_as_they_are() {
        let request = Request {
            html:
                "<h2>Title</h2><ul><li>one</li><li><a href=\"https://x.example/\">two</a></li></ul>"
                    .into(),
            url: String::new(),
            format: Format::Markdown,
            fragment: true,
        };
        let markdown = extract(&request).content;
        assert!(markdown.contains("## Title"), "{markdown}");
        assert!(markdown.contains("[two](https://x.example/)"), "{markdown}");
        let text = extract(&Request {
            format: Format::Text,
            ..request
        })
        .content;
        assert_eq!(text, "Title one two");
    }

    #[test]
    fn short_pages_keep_their_structure() {
        let html = "<html><head><title>Doc</title><script>x()</script></head><body>\
            <nav>menu</nav><h1>Heading</h1><ul><li>one</li><li>two</li></ul></body></html>";
        let markdown = extract(&Request {
            html: html.into(),
            url: String::new(),
            format: Format::Markdown,
            fragment: false,
        })
        .content;
        assert!(markdown.contains("# Heading"), "{markdown}");
        assert!(markdown.contains("*   one"), "{markdown}");
        assert!(!markdown.contains("x()"), "{markdown}");
    }

    #[test]
    fn whole_pages_keep_their_structure() {
        let html = "<html><head><title>Doc</title></head><body><nav>menu</nav><article>\
            <h1>Heading</h1><p>First paragraph with <a href=\"https://x.example/\">a link</a>, \
            long enough to be the article rather than boilerplate around it, and then some more \
            words so that the readability scorer is confident about it.</p>\
            <ul><li>one</li><li>two</li></ul></article></body></html>";
        let markdown = extract(&Request {
            html: html.into(),
            url: "https://doc.example/".into(),
            format: Format::Markdown,
            fragment: false,
        })
        .content;
        assert!(
            markdown.contains("[a link](https://x.example/)"),
            "{markdown}"
        );
        assert!(
            markdown.contains("*   one") || markdown.contains("- one"),
            "{markdown}"
        );
    }
}
