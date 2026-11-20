use std::{env, fs, path::Path};

fn has_history_db(source: &str) -> bool {
    let signature = source
        .split_once("pub async fn execute_search_full(")
        .and_then(|(_, rest)| rest.split_once(')'))
        .expect("SearchWala must expose execute_search_full")
        .0;
    signature.contains("history_db:")
}

fn main() {
    // HistoryDb was removed without changing upstream's crate version.
    let source = Path::new(&env::var_os("CARGO_MANIFEST_DIR").unwrap())
        .join("../vendor-searchwala/src/search.rs");
    println!("cargo:rerun-if-changed={}", source.display());
    println!("cargo:rustc-check-cfg=cfg(searchwala_history_db)");
    if has_history_db(&fs::read_to_string(source).expect("read SearchWala search API")) {
        println!("cargo:rustc-cfg=searchwala_history_db");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_with_history() {
        assert!(has_history_db(
            "pub async fn execute_search_full(
                params: SearchParams,
                temp_db: Option<&crate::cache::TempDb>,
                history_db: Option<&crate::cache::HistoryDb>,
                progress: Option<tokio::sync::mpsc::Sender<Progress>>,
            ) -> SearchResponse {"
        ));
    }

    #[test]
    fn pipeline_without_history() {
        assert!(!has_history_db(
            "pub async fn execute_search_full(
                params: SearchParams,
                temp_db: Option<&crate::cache::TempDb>,
                progress: Option<tokio::sync::mpsc::Sender<Progress>>,
            ) -> SearchResponse {
                // history_db: no longer part of the API
            }"
        ));
    }

    #[test]
    #[should_panic(expected = "SearchWala must expose execute_search_full")]
    fn missing_entry_point_is_not_silently_accepted() {
        has_history_db("");
    }
}
