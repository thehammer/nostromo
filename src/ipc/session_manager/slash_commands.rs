//! The slash commands a session's CLI reports, read from the passive stream.
//!
//! Two events carry them (Claude Code 2.1.318):
//!
//! * `system`/`init` names the commands (`slash_commands: [names]`), once the
//!   first user message has arrived.
//! * `system`/`commands_changed` describes every command, unsolicited, once the
//!   session has started and again whenever commands change (MCP connects,
//!   skills reload).
//!
//! The daemon NEVER sends `initialize` to a live session to ask: it may reset
//! SDK state (hooks, the permission tool). Memory only, never written to disk.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use serde_json::Value;

use crate::data::work::untrusted::{one_line, sanitize_block};
use crate::ipc::protocol::SlashCommandEntry;

/// Entries one catalog keeps.
pub const MAX_ENTRIES: usize = 500;
const DESCRIPTION_CHARS: usize = 200;
const ARGUMENT_HINT_CHARS: usize = 80;
const MAX_ALIASES: usize = 8;
const ALIAS_CHARS: usize = 32;
/// A line longer than this is not parsed for commands.
const MAX_LINE_BYTES: usize = 4 * 1024 * 1024;

/// Where a catalog's entries came from, as `SessionCommands.source` says.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CatalogSource {
    /// Nothing reported yet.
    #[default]
    None,
    /// `init`: names only.
    Init,
    /// `commands_changed`: described entries.
    Cli,
}

impl CatalogSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Init => "init",
            Self::Cli => "cli",
        }
    }
}

/// What one stream line reported.
#[derive(Debug, Clone, PartialEq)]
pub struct CatalogUpdate {
    pub source: CatalogSource,
    pub entries: Vec<SlashCommandEntry>,
}

/// One session tag's commands, kept for the daemon's lifetime.
#[derive(Debug, Default)]
pub struct CommandCatalog {
    inner: Mutex<(CatalogSource, Vec<SlashCommandEntry>)>,
}

impl CommandCatalog {
    /// Take in what a line reported. `commands_changed` replaces whatever was
    /// there; `init` (names only) never replaces a described list, which the
    /// `commands_changed` that follows a restart's `init` refreshes.
    pub fn apply(&self, update: CatalogUpdate) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if update.source == CatalogSource::Init && inner.0 == CatalogSource::Cli {
            return;
        }
        *inner = (update.source, update.entries);
    }

    pub fn snapshot(&self) -> (CatalogSource, Vec<SlashCommandEntry>) {
        self.inner.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

/// The daemon's catalogs, one per focus tag, kept across restarts of its
/// process (never persisted).
#[derive(Debug, Default)]
pub struct CommandBook {
    by_tag: Mutex<HashMap<String, Arc<CommandCatalog>>>,
}

impl CommandBook {
    /// The catalog for `tag`, made on first use.
    pub fn for_tag(&self, tag: &str) -> Arc<CommandCatalog> {
        let mut by_tag = self.by_tag.lock().unwrap_or_else(|e| e.into_inner());
        Arc::clone(by_tag.entry(tag.to_owned()).or_default())
    }

    /// What `tag` last reported; nothing for a tag never seen.
    pub fn snapshot(&self, tag: &str) -> (CatalogSource, Vec<SlashCommandEntry>) {
        let by_tag = self.by_tag.lock().unwrap_or_else(|e| e.into_inner());
        by_tag
            .get(tag)
            .map(|c| c.snapshot())
            .unwrap_or_else(|| (CatalogSource::None, Vec::new()))
    }
}

/// The commands `raw` (one stdout line) reports, if it is an `init` or a
/// `commands_changed` event. Gated on cheap substring checks before any JSON
/// parse, as every other line is by far the common case.
pub fn observe(raw: &str) -> Option<CatalogUpdate> {
    let changed = raw.contains("\"commands_changed\"");
    if !(changed || raw.contains("\"slash_commands\"")) || raw.len() > MAX_LINE_BYTES {
        return None;
    }
    let v: Value = serde_json::from_str(raw).ok()?;
    if v.get("type")?.as_str()? != "system" {
        return None;
    }
    match v.get("subtype")?.as_str()? {
        "commands_changed" => {
            let entries = v
                .get("commands")?
                .as_array()?
                .iter()
                .filter_map(entry_of)
                .take(MAX_ENTRIES)
                .collect();
            Some(CatalogUpdate {
                source: CatalogSource::Cli,
                entries,
            })
        }
        "init" => {
            let entries = v
                .get("slash_commands")?
                .as_array()?
                .iter()
                .filter_map(|n| n.as_str())
                .filter(|n| insertable(n))
                .take(MAX_ENTRIES)
                .map(|name| SlashCommandEntry {
                    name: name.to_owned(),
                    description: None,
                    argument_hint: None,
                    aliases: vec![],
                    builtin: false,
                })
                .collect();
            Some(CatalogUpdate {
                source: CatalogSource::Init,
                entries,
            })
        }
        _ => None,
    }
}

/// Longest name or alias kept (the limit command records use).
const NAME_CHARS: usize = 64;

/// A name the picker can insert reliably and show faithfully: non-empty, at
/// most [`NAME_CHARS`] long, with no whitespace, control character, ANSI escape
/// or invisible/bidi formatting character. Such a name is dropped, never
/// "cleaned" into a different command.
fn insertable(name: &str) -> bool {
    !name.is_empty()
        && name.chars().count() <= NAME_CHARS
        && !name.chars().any(|c| {
            c.is_whitespace()
                || c.is_control()
                || matches!(
                    c,
                    '\u{200B}'..='\u{200F}'
                        | '\u{202A}'..='\u{202E}'
                        | '\u{2066}'..='\u{2069}'
                        | '\u{FEFF}'
                )
        })
}

/// One `commands_changed` entry; `None` when malformed or not insertable.
fn entry_of(v: &Value) -> Option<SlashCommandEntry> {
    let name = v.get("name")?.as_str()?;
    if !insertable(name) {
        return None;
    }
    let text = |key: &str, max: usize| {
        let cleaned = sanitize_block(v.get(key)?.as_str()?);
        let first = cleaned.lines().next().unwrap_or_default();
        Some(one_line(first, max)).filter(|t| !t.is_empty())
    };
    let aliases = v
        .get("aliases")
        .and_then(|a| a.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str())
                .filter(|x| insertable(x))
                .map(|x| one_line(x, ALIAS_CHARS))
                .take(MAX_ALIASES)
                .collect()
        })
        .unwrap_or_default();
    Some(SlashCommandEntry {
        name: name.to_owned(),
        description: text("description", DESCRIPTION_CHARS),
        argument_hint: text("argumentHint", ARGUMENT_HINT_CHARS),
        aliases,
        builtin: v.get("builtin").and_then(|b| b.as_bool()) == Some(true),
    })
}
