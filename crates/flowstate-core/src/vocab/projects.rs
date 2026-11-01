//! Pull vocabulary out of a projects folder: project names, package names,
//! and README titles. Contacts and calendar are platform APIs, so the app
//! shells index those and hand the names to the core.

use regex::Regex;
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::sync::LazyLock;

const MANIFESTS: &[&str] = &["Cargo.toml", "package.json", "pyproject.toml", "go.mod", "Package.swift", "pubspec.yaml"];
const SKIP_DIRS: &[&str] = &["node_modules", "target", "build", "dist", "vendor", "venv", ".venv"];

static TOML_NAME: LazyLock<Regex> = LazyLock::new(|| Regex::new(r#"(?m)^name\s*=\s*"([^"]+)""#).unwrap());
static GO_MODULE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^module\s+(\S+)").unwrap());
static README_TITLE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?m)^#\s+(.+?)\s*$").unwrap());

/// Collect terms from every project under `root`. A direct child counts as a
/// project if it has a `.git` folder or a known manifest; otherwise it's
/// treated as a group folder (like `Sidequests/`) and its children are checked.
pub fn index_projects(root: &Path) -> std::io::Result<Vec<String>> {
    let mut terms = BTreeSet::new();
    for entry in visible_dirs(root)? {
        if is_project(&entry) {
            collect_project(&entry, &mut terms);
        } else {
            add_name(&entry, &mut terms);
            for child in visible_dirs(&entry)? {
                if is_project(&child) {
                    collect_project(&child, &mut terms);
                }
            }
        }
    }
    Ok(terms.into_iter().collect())
}

fn visible_dirs(dir: &Path) -> std::io::Result<Vec<std::path::PathBuf>> {
    let mut out = Vec::new();
    for entry in fs::read_dir(dir)? {
        let path = entry?.path();
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
        if path.is_dir() && !name.starts_with('.') && !SKIP_DIRS.contains(&name) {
            out.push(path);
        }
    }
    out.sort();
    Ok(out)
}

fn is_project(dir: &Path) -> bool {
    dir.join(".git").exists() || MANIFESTS.iter().any(|m| dir.join(m).exists())
}

fn collect_project(dir: &Path, terms: &mut BTreeSet<String>) {
    add_name(dir, terms);

    for file in ["Cargo.toml", "pyproject.toml"] {
        if let Ok(text) = fs::read_to_string(dir.join(file)) {
            for cap in TOML_NAME.captures_iter(&text).take(1) {
                add(&cap[1], terms);
            }
        }
    }
    if let Ok(text) = fs::read_to_string(dir.join("package.json")) {
        if let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) {
            if let Some(name) = json.get("name").and_then(|n| n.as_str()) {
                // "@scope/name" → "name"
                add(name.rsplit('/').next().unwrap_or(name), terms);
            }
        }
    }
    if let Ok(text) = fs::read_to_string(dir.join("go.mod")) {
        if let Some(cap) = GO_MODULE.captures(&text) {
            add(cap[1].rsplit('/').next().unwrap_or(&cap[1]), terms);
        }
    }
    for readme in ["README.md", "readme.md", "Readme.md"] {
        if let Ok(text) = fs::read_to_string(dir.join(readme)) {
            if let Some(cap) = README_TITLE.captures(&text) {
                let title = cap[1].trim_matches(['*', '`', ' ']);
                // Short titles are names; long ones are taglines.
                if title.split_whitespace().count() <= 4 {
                    add(title, terms);
                }
            }
            break;
        }
    }
}

fn add_name(dir: &Path, terms: &mut BTreeSet<String>) {
    if let Some(name) = dir.file_name().and_then(|n| n.to_str()) {
        add(name, terms);
    }
}

fn add(term: &str, terms: &mut BTreeSet<String>) {
    let term = term.trim();
    if term.chars().filter(|c| c.is_alphanumeric()).count() >= 3 && term.len() <= 60 {
        terms.insert(term.to_string());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_projects_and_groups() {
        let root = tempfile::tempdir().unwrap();
        let p = root.path();
        fs::create_dir_all(p.join("Kinju/.git")).unwrap();
        fs::write(p.join("Kinju/package.json"), r#"{"name": "@kinju/kinju-web"}"#).unwrap();
        fs::create_dir_all(p.join("Sidequests/kalshi")).unwrap();
        fs::write(p.join("Sidequests/kalshi/Cargo.toml"), "[package]\nname = \"kalshi-bot\"\n").unwrap();
        fs::write(p.join("Sidequests/kalshi/README.md"), "# Kalshi Edge\n\nTrading notes.").unwrap();
        fs::create_dir_all(p.join("Sidequests/notes-not-a-project")).unwrap();
        fs::create_dir_all(p.join("node_modules/junk/.git")).unwrap();

        let terms = index_projects(p).unwrap();
        assert_eq!(terms, ["Kalshi Edge", "Kinju", "Sidequests", "kalshi", "kalshi-bot", "kinju-web"]);
    }
}
