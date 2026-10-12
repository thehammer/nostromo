//! The model catalogue: which model families the installed Claude CLI offers.
//!
//! Filled by an `initialize` probe (contract F7): the CLI answers the
//! `initialize` control request with a `models` list without making an API
//! call. Rows whose `value` is `default` or starts with `claude-` are not
//! families: `default` resolves to something that ignores the managed policy
//! (F6/F7) and is never offered, and `claude-…` rows are pinned versions.
//!
//! The catalogue is cached on disk so a daemon whose probe fails still offers
//! the families it last saw, flagged `stale`.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

use super::cost::family_rank;
use crate::ipc::protocol::ModelFamilyWire;

/// How long the `initialize` probe may take, process start included.
pub const PROBE_TIMEOUT: Duration = Duration::from_secs(10);

/// How often the daemon re-probes the catalogue.
pub const PROBE_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);

/// One row of the CLI's model list.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ModelEntry {
    /// What `--model` / `set_model` accepts: a family alias or a full name.
    pub value: String,
    /// The full model name the row currently resolves to.
    #[serde(default)]
    pub resolved_model: Option<String>,
    #[serde(default)]
    pub display_name: Option<String>,
    /// Effort levels the model accepts; empty when it has no effort support.
    #[serde(default)]
    pub supported_effort_levels: Vec<String>,
    #[serde(default)]
    pub supports_effort: bool,
}

impl ModelEntry {
    /// Does this model accept an explicit effort `level`?
    pub fn supports_effort_level(&self, level: &str) -> bool {
        self.supports_effort && self.supported_effort_levels.iter().any(|l| l == level)
    }
}

/// The families and pinned versions the installed CLI offers.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct ModelCatalog {
    /// Family aliases, cheapest first (unknown families last, alphabetical).
    #[serde(default)]
    pub families: Vec<ModelEntry>,
    /// Pinned versions (`claude-…`).
    #[serde(default)]
    pub pinned: Vec<ModelEntry>,
    #[serde(default)]
    pub fetched_at: Option<DateTime<Utc>>,
    /// The last probe failed: these rows are what an earlier probe saw.
    #[serde(default)]
    pub stale: bool,
}

impl ModelCatalog {
    /// Build a catalogue from the rows of an `initialize` response.
    pub fn from_rows(rows: Vec<ModelEntry>, fetched_at: DateTime<Utc>) -> Self {
        let mut families = Vec::new();
        let mut pinned = Vec::new();
        for row in rows {
            if row.value == "default" || row.value.is_empty() {
                continue;
            }
            if row.value.starts_with("claude-") {
                pinned.push(row);
            } else {
                families.push(row);
            }
        }
        families.sort_by(|a, b| {
            family_rank(&a.value)
                .cmp(&family_rank(&b.value))
                .then_with(|| a.value.cmp(&b.value))
        });
        Self {
            families,
            pinned,
            fetched_at: Some(fetched_at),
            stale: false,
        }
    }

    /// Parse the `control_response` (or any JSON holding it) the CLI returns
    /// for `initialize`. `None` when it carries no `models` list.
    pub fn from_initialize_response(response: &Value, fetched_at: DateTime<Utc>) -> Option<Self> {
        let models = find_key(response, "models")?.as_array()?;
        let rows = models.iter().filter_map(parse_row).collect();
        Some(Self::from_rows(rows, fetched_at))
    }

    /// Nothing known: never probed and no cache.
    pub fn is_empty(&self) -> bool {
        self.families.is_empty() && self.pinned.is_empty()
    }

    /// The family row with this alias.
    pub fn family(&self, alias: &str) -> Option<&ModelEntry> {
        self.families.iter().find(|e| e.value == alias)
    }

    /// The row (family or pinned) whose `value` is `model`.
    pub fn entry(&self, model: &str) -> Option<&ModelEntry> {
        self.family(model)
            .or_else(|| self.pinned.iter().find(|e| e.value == model))
    }

    /// The full name `model` currently resolves to: the catalogue's
    /// `resolvedModel` for a listed row, the name itself for a `claude-…` name.
    pub fn resolved(&self, model: &str) -> Option<String> {
        match self.entry(model) {
            Some(e) => e
                .resolved_model
                .clone()
                .or_else(|| model.starts_with("claude-").then(|| model.to_owned())),
            None => model.starts_with("claude-").then(|| model.to_owned()),
        }
    }

    /// The family alias whose resolved name is `resolved`.
    pub fn family_for_resolved(&self, resolved: &str) -> Option<&ModelEntry> {
        self.families
            .iter()
            .find(|e| e.resolved_model.as_deref() == Some(resolved))
    }

    /// Load the cached catalogue; an absent or unreadable cache is empty.
    pub fn load(path: &Path) -> Self {
        std::fs::read(path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    /// Write the catalogue atomically.
    pub fn save(&self, path: &Path) -> Result<()> {
        super::store::write_json_atomic(path, self)
    }

    /// The families as sent to clients.
    pub fn families_wire(&self) -> Vec<ModelFamilyWire> {
        self.families
            .iter()
            .map(|e| ModelFamilyWire {
                alias: e.value.clone(),
                display_name: e
                    .display_name
                    .clone()
                    .unwrap_or_else(|| family_display(&e.value)),
                resolved: e.resolved_model.clone(),
                efforts: if e.supports_effort {
                    e.supported_effort_levels.clone()
                } else {
                    vec![]
                },
                rank: family_rank(&e.value),
            })
            .collect()
    }
}

/// `"opus"` → `"Opus"`.
pub fn family_display(alias: &str) -> String {
    let mut chars = alias.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    }
}

fn parse_row(v: &Value) -> Option<ModelEntry> {
    let value = v.get("value")?.as_str()?.to_owned();
    let str_field = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
    Some(ModelEntry {
        value,
        resolved_model: str_field("resolvedModel"),
        display_name: str_field("displayName"),
        supported_effort_levels: v
            .get("supportedEffortLevels")
            .and_then(Value::as_array)
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default(),
        supports_effort: v
            .get("supportsEffort")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    })
}

/// Depth-first search for the first value stored under `key`.
fn find_key<'a>(v: &'a Value, key: &str) -> Option<&'a Value> {
    match v {
        Value::Object(map) => map
            .get(key)
            .or_else(|| map.values().find_map(|child| find_key(child, key))),
        Value::Array(items) => items.iter().find_map(|child| find_key(child, key)),
        _ => None,
    }
}

/// Ask the CLI at `claude` for its model list: start it in stream-json mode
/// with nothing loaded, send `initialize`, read the answer, kill it.
pub async fn probe(claude: &Path) -> Result<ModelCatalog> {
    tokio::time::timeout(PROBE_TIMEOUT, probe_inner(claude))
        .await
        .map_err(|_| anyhow!("model catalogue probe timed out"))?
}

async fn probe_inner(claude: &Path) -> Result<ModelCatalog> {
    let mut child = tokio::process::Command::new(claude)
        .args([
            "-p",
            "--input-format",
            "stream-json",
            "--output-format",
            "stream-json",
            "--verbose",
            "--setting-sources",
            "project",
            "--strict-mcp-config",
            "--tools",
            "",
        ])
        .current_dir(std::env::temp_dir())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("starting {}", claude.display()))?;

    let request_id = format!("catalog-{}", uuid::Uuid::new_v4());
    let frame = serde_json::json!({
        "type": "control_request",
        "request_id": request_id,
        "request": { "subtype": "initialize" },
    });
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| anyhow!("probe has no stdin"))?;
    stdin.write_all(format!("{frame}\n").as_bytes()).await?;
    stdin.flush().await?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| anyhow!("probe has no stdout"))?;
    let mut lines = BufReader::new(stdout).lines();
    let result = loop {
        let Some(line) = lines.next_line().await? else {
            break Err(anyhow!("the CLI exited before answering initialize"));
        };
        let Ok(v) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if v.get("type").and_then(Value::as_str) != Some("control_response") {
            continue;
        }
        let response = v.get("response").unwrap_or(&Value::Null);
        if response.get("request_id").and_then(Value::as_str) != Some(request_id.as_str()) {
            continue;
        }
        if response.get("subtype").and_then(Value::as_str) == Some("error") {
            let error = response
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("error");
            break Err(anyhow!("initialize failed: {error}"));
        }
        break ModelCatalog::from_initialize_response(response, Utc::now())
            .ok_or_else(|| anyhow!("initialize returned no models"));
    };
    drop(stdin);
    let _ = child.kill().await;
    result
}
