# SearchWala - Embedded Edition

`searchwala-calf`: SearchWala's search pipeline and page parsing, and
nothing else of its surface (no UI, no storage, no server of its own),
behind a unix socket. The browser's start page and default engine point at
it.

| Route | Answers |
| --- | --- |
| `GET /search?q=…[&mode=…][&max_results=…]` | NDJSON (`application/x-ndjson`), one object per line tagged by `type`: the pipeline's stages as they happen (`plan`, `engines`, `sources` with the ranked hits, `extracted`, `highlight`, `synthesizing`), then `result` with SearchWala's full response (many engines, consensus ranking, a verbatim highlight) or `error`. One document: read to the end, keep `result`. With `Accept: application/json`: the query's JSON Schema instead |
| `POST /extract` | Parsing for HTML the caller already holds: `{ html, url, format, fragment }` → Markdown, text, or JSON with metadata; nothing fetched |
| `GET /health` | `ok` |
| `/` (served by the host's vhost) | `page/index.html`; `/?q=` runs a query on arrival |

`LISTEN_UNIX` names the socket (mode 0666; `HOST`/`PORT` for TCP where a
socket does not fit). LLM synthesis stays off unless `CALF_LLM_PROVIDER`,
`CALF_LLM_MODEL` and `CALF_LLM_API_KEY` are set (`CALF_LLM_BASE_URL` for a
gateway); spans ship over OTLP when `OTEL_EXPORTER_OTLP_ENDPOINT` is set,
query text never.

SearchWala is a path dependency on the `searchwala-calf` pin, SearchWala's
newest stamped release (`vX.Y.Z-YYYYMMDD-HHMM`), assembled beside the crate
(`crate/`) at build time. The crate's `Cargo.lock` is written against that
release: `toolkit cargo-lock searchwala-calf` regenerates it in the
assembled tree (`.src`), and `toolkit verify` does so whenever the pin
moves. As a service:
`nixosModules.searchwala-calf` (hardened systemd unit, secrets through
`environmentFile`) and `darwinModules.searchwala-calf` (launchd user agent,
socket under `/tmp`).
