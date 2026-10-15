//! The board model: what a parsed board file means, independent of its bytes.
//!
//! `format.rs` turns bytes into a [`Board`] (and back); `ops.rs` edits a
//! `Board`; `diff.rs` compares two. Vocabularies carry their wire names (the
//! names agents and the pane see) and their file words (what a human reads in
//! the markdown) side by side so the two never drift.

use std::collections::{BTreeMap, HashSet};
use std::sync::OnceLock;

use chrono::{DateTime, FixedOffset, Utc};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// An item's state. Wire names are kebab-case (`in-progress`); file words are
/// spaced (`in progress`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Status {
    #[default]
    Todo,
    InProgress,
    Blocked,
    NeedsYou,
    Done,
}

impl Status {
    pub const ALL: [Status; 5] = [
        Status::Todo,
        Status::InProgress,
        Status::Blocked,
        Status::NeedsYou,
        Status::Done,
    ];

    /// The wire name (`todo`, `in-progress`, `blocked`, `needs-you`, `done`).
    pub fn wire(self) -> &'static str {
        match self {
            Status::Todo => "todo",
            Status::InProgress => "in-progress",
            Status::Blocked => "blocked",
            Status::NeedsYou => "needs-you",
            Status::Done => "done",
        }
    }

    /// The word written in the file's visible tail (`in progress`).
    pub fn word(self) -> &'static str {
        match self {
            Status::Todo => "todo",
            Status::InProgress => "in progress",
            Status::Blocked => "blocked",
            Status::NeedsYou => "needs you",
            Status::Done => "done",
        }
    }

    /// Parses a wire name. Also accepts the file word and `_` for `-`, so an
    /// agent writing `in_progress` or `in progress` is understood.
    pub fn from_wire(s: &str) -> Option<Status> {
        let norm = s.trim().to_ascii_lowercase().replace(['_', ' '], "-");
        Status::ALL.into_iter().find(|st| st.wire() == norm)
    }

    /// Parses a file word (case-insensitive).
    pub fn from_word(s: &str) -> Option<Status> {
        Status::ALL
            .into_iter()
            .find(|st| st.word().eq_ignore_ascii_case(s.trim()))
    }
}

/// Plain item or a staged command (display-only; T4).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    #[default]
    Item,
    Command,
}

impl Kind {
    pub fn wire(self) -> &'static str {
        match self {
            Kind::Item => "item",
            Kind::Command => "command",
        }
    }

    pub fn from_wire(s: &str) -> Option<Kind> {
        match s.trim().to_ascii_lowercase().as_str() {
            "item" => Some(Kind::Item),
            "command" => Some(Kind::Command),
            _ => None,
        }
    }
}

/// The environment a command targets. `Unset` is "an environment matters but
/// nobody said which", shown as `ENV?`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Env {
    Prod,
    Canada,
    Demo,
    Staging,
    Local,
    Unset,
}

impl Env {
    pub const ALL: [Env; 6] = [
        Env::Prod,
        Env::Canada,
        Env::Demo,
        Env::Staging,
        Env::Local,
        Env::Unset,
    ];

    pub fn wire(self) -> &'static str {
        match self {
            Env::Prod => "prod",
            Env::Canada => "canada",
            Env::Demo => "demo",
            Env::Staging => "staging",
            Env::Local => "local",
            Env::Unset => "unset",
        }
    }

    /// The token written in the file's visible tail (`PROD`, `ENV?`).
    pub fn token(self) -> &'static str {
        match self {
            Env::Prod => "PROD",
            Env::Canada => "CANADA",
            Env::Demo => "DEMO",
            Env::Staging => "STAGING",
            Env::Local => "LOCAL",
            Env::Unset => "ENV?",
        }
    }

    pub fn from_wire(s: &str) -> Option<Env> {
        let norm = s.trim().to_ascii_lowercase();
        Env::ALL.into_iter().find(|e| e.wire() == norm)
    }

    /// Parses a file token. Exact case: `prod` in a tail is an owner, not an
    /// environment.
    pub fn from_token(s: &str) -> Option<Env> {
        Env::ALL.into_iter().find(|e| e.token() == s)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LinkKind {
    Pr,
    Jira,
    Sentry,
    Run,
    File,
    /// A plain URL, or text the recogniser doesn't classify.
    Url,
}

/// A reference attached to an item (`Links: ` line in the file).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Link {
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    pub kind: LinkKind,
}

impl Link {
    /// Builds a link from its display text and optional URL, classifying it:
    /// `PR #253` → pr, `CORE-2841` → jira, `Sentry PORTAL-1F2` → sentry,
    /// `run 9912` → run, `index.md:42` → file, `https://…` → url. With no text
    /// match, the URL decides (GitHub pull → pr, `/browse/KEY-1` → jira,
    /// sentry host → sentry); otherwise `url`.
    pub fn new(text: &str, url: Option<&str>) -> Link {
        let text = text.trim().to_string();
        let url = url.map(|u| u.trim().to_string()).filter(|u| !u.is_empty());
        let kind = kind_from_text(&text)
            .or_else(|| url.as_deref().and_then(kind_from_url))
            .unwrap_or(LinkKind::Url);
        Link { text, url, kind }
    }

    /// Parses one `Links:` token: `[text](url)` or bare text.
    pub fn parse_token(token: &str) -> Link {
        let t = token.trim();
        if let Some(caps) = md_link_re().captures(t) {
            return Link::new(&caps[1], Some(&caps[2]));
        }
        Link::new(t, None)
    }

    /// The token as written in the file.
    pub fn to_token(&self) -> String {
        match &self.url {
            Some(url) => format!("[{}]({})", self.text, url),
            None => self.text.clone(),
        }
    }
}

fn md_link_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^\[([^\]]*)\]\(([^)\s]*)\)$").unwrap())
}

fn kind_from_text(text: &str) -> Option<LinkKind> {
    static RES: OnceLock<[(Regex, LinkKind); 5]> = OnceLock::new();
    if text.starts_with("http://") || text.starts_with("https://") {
        return Some(kind_from_url(text).unwrap_or(LinkKind::Url));
    }
    let res = RES.get_or_init(|| {
        [
            (Regex::new(r"(?i)^PR\s*#?\d+$").unwrap(), LinkKind::Pr),
            (Regex::new(r"(?i)^sentry\s+\S+$").unwrap(), LinkKind::Sentry),
            (Regex::new(r"(?i)^run\s+#?\S+$").unwrap(), LinkKind::Run),
            (Regex::new(r"^[A-Z][A-Z0-9]+-\d+$").unwrap(), LinkKind::Jira),
            (
                Regex::new(r"^[\w./~-]*\w\.[A-Za-z0-9]{1,8}(:\d+(-\d+)?)?$").unwrap(),
                LinkKind::File,
            ),
        ]
    });
    res.iter().find(|(re, _)| re.is_match(text)).map(|(_, k)| *k)
}

fn kind_from_url(url: &str) -> Option<LinkKind> {
    let lower = url.to_ascii_lowercase();
    if lower.contains("github.com/") && lower.contains("/pull/") {
        Some(LinkKind::Pr)
    } else if lower.contains("/browse/") {
        Some(LinkKind::Jira)
    } else if lower.contains("sentry.io") || lower.contains("sentry.") {
        Some(LinkKind::Sentry)
    } else {
        None
    }
}

/// A `## ` section (the Log section is not one of these; see [`Board::log`]).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    /// Slug of the heading text, `-2`, `-3` … for duplicates.
    pub id: String,
    pub title: String,
}

/// One task-list line and its indented block.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    /// Id of the section the item sits under.
    pub section: String,
    pub text: String,
    pub status: Status,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner: Option<String>,
    /// Markdown, kept verbatim (indentation removed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub links: Vec<Link>,
    #[serde(default)]
    pub kind: Kind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env: Option<Env>,
    /// `bind:<source>/<key>` marker flag (T6), stored as `<source>/<key>`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bind: Option<String>,
    /// From the marker; `None` on a human line that has no marker yet.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub updated_at: Option<DateTime<Utc>>,
}

impl Item {
    /// A plain `todo` item with no extras.
    pub fn new(id: &str, section: &str, text: &str) -> Item {
        Item {
            id: id.to_string(),
            section: section.to_string(),
            text: text.to_string(),
            status: Status::Todo,
            owner: None,
            note: None,
            links: Vec::new(),
            kind: Kind::Item,
            command: None,
            env: None,
            bind: None,
            updated_at: None,
        }
    }
}

/// A `- HH:MM text` line in the Log section.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LogLine {
    /// As written (`10:42`).
    pub time: String,
    pub text: String,
}

/// Item counts by status (the `open` response's `counts`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Counts {
    pub todo: usize,
    pub in_progress: usize,
    pub blocked: usize,
    pub needs_you: usize,
    pub done: usize,
}

/// A parsed board. `items` are in file order.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Board {
    /// The first `# ` line; `None` when absent (callers fall back to the topic).
    pub title: Option<String>,
    /// `## ` sections in file order, excluding the Log section.
    pub sections: Vec<Section>,
    pub items: Vec<Item>,
    /// Free prose blocks, verbatim, in file order.
    pub prose: Vec<String>,
    pub log: Vec<LogLine>,
    /// Size of the file this board was parsed from (0 for a constructed board).
    /// Used to estimate the size of a write for the size cap.
    pub byte_len: usize,
}

impl Board {
    pub fn item(&self, id: &str) -> Option<&Item> {
        self.items.iter().find(|i| i.id == id)
    }

    pub fn section(&self, id: &str) -> Option<&Section> {
        self.sections.iter().find(|s| s.id == id)
    }

    /// Resolves a section reference: an exact id, or anything whose slug is
    /// an id (`"Waiting on you"` → `waiting-on-you`).
    pub fn resolve_section(&self, reference: &str) -> Option<&Section> {
        self.section(reference)
            .or_else(|| self.section(&slug(reference)))
    }

    pub fn counts(&self) -> Counts {
        let mut c = Counts::default();
        for item in &self.items {
            match item.status {
                Status::Todo => c.todo += 1,
                Status::InProgress => c.in_progress += 1,
                Status::Blocked => c.blocked += 1,
                Status::NeedsYou => c.needs_you += 1,
                Status::Done => c.done += 1,
            }
        }
        c
    }

    /// The board's updated time: the latest item `updated_at`.
    pub fn updated_at(&self) -> Option<DateTime<Utc>> {
        self.items.iter().filter_map(|i| i.updated_at).max()
    }
}

/// `true` when `id` is a valid item id (`^[a-z0-9][a-z0-9-]{0,31}$`).
pub fn is_valid_id(id: &str) -> bool {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"^[a-z0-9][a-z0-9-]{0,31}$").unwrap())
        .is_match(id)
}

/// Lowercase, ASCII alphanumerics, runs of anything else collapsed to `-`.
pub fn slug(text: &str) -> String {
    let mut out = String::new();
    for ch in text.trim().chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else if !out.is_empty() && !out.ends_with('-') {
            out.push('-');
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}

/// Generates an item id: the slug of the text's first word (≤ 27 chars, or
/// `item`) + `-` + 4 base36 chars of an FNV-1a hash of the text. Rehashes
/// with a salt until the id is not in `taken`. Deterministic.
pub fn generate_id(text: &str, taken: &HashSet<String>) -> String {
    let first = text.split_whitespace().next().map(slug).unwrap_or_default();
    let mut word: String = first.split('-').next().unwrap_or("").chars().take(27).collect();
    if word.is_empty() {
        word = "item".to_string();
    }
    let mut salt: u32 = 0;
    loop {
        let mut input = text.as_bytes().to_vec();
        if salt > 0 {
            input.extend_from_slice(format!("#{salt}").as_bytes());
        }
        let id = format!("{word}-{}", base36_4(fnv1a64(&input)));
        if !taken.contains(&id) {
            return id;
        }
        salt += 1;
    }
}

/// FNV-1a 64-bit. Stable across Rust versions (unlike `DefaultHasher`).
pub fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

fn base36_4(mut n: u64) -> String {
    const DIGITS: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";
    n %= 36u64.pow(4);
    let mut out = [b'0'; 4];
    for slot in out.iter_mut().rev() {
        *slot = DIGITS[(n % 36) as usize];
        n /= 36;
    }
    String::from_utf8(out.to_vec()).unwrap()
}

/// "Now" for a write: the instant (for markers and change records) and the
/// local UTC offset (for the `HH:MM` the file shows).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stamp {
    pub now: DateTime<Utc>,
    pub offset: FixedOffset,
}

impl Stamp {
    pub fn new(now: DateTime<Utc>, offset: FixedOffset) -> Stamp {
        Stamp { now, offset }
    }

    /// `now` with a UTC offset of zero.
    pub fn utc(now: DateTime<Utc>) -> Stamp {
        Stamp::new(now, FixedOffset::east_opt(0).unwrap())
    }

    /// `HH:MM` of `at` in this stamp's offset.
    pub fn hhmm(&self, at: DateTime<Utc>) -> String {
        at.with_timezone(&self.offset).format("%H:%M").to_string()
    }
}

/// Who made a change (contract §3).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Author {
    /// An agent's tool write.
    Agent {
        focus: String,
        session_id: String,
        name: String,
    },
    /// The user, in Nostromo's pane.
    Pane,
    /// Anything that edited the file (an editor, a script, `git pull`).
    File,
    /// A live data source (T6).
    Source { name: String },
}

impl Author {
    /// The attribution shown to agents: `agent <name>`, `pane (you)`,
    /// `file (unknown editor)`, `source <name>`.
    pub fn label(&self) -> String {
        match self {
            Author::Agent { name, .. } => format!("agent {name}"),
            Author::Pane => "pane (you)".to_string(),
            Author::File => "file (unknown editor)".to_string(),
            Author::Source { name } => format!("source {name}"),
        }
    }

    /// The agent session id, if this is an agent.
    pub fn session_id(&self) -> Option<&str> {
        match self {
            Author::Agent { session_id, .. } => Some(session_id),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChangeKind {
    /// `fields` holds the new item's fields as `(null, value)`.
    Added,
    /// `fields` holds each changed field as `(old, new)`.
    Changed,
    /// `fields["section"]` = `(old section id, new section id)`; equal when
    /// reordered within a section.
    Moved,
    /// `fields` holds the removed item's `section` and `text` as `(value, null)`.
    Removed,
    /// `fields["text"]` = `(null, "HH:MM text")`.
    Log,
    /// `fields["id"]` and `fields["title"]`: `(null, new)` added, `(old, null)`
    /// removed, `(old, new)` renamed.
    Section,
}

/// One attributed, field-level change (contract §3).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Change {
    /// Assigned by [`crate::tracker::changelog::ChangeLog::append`]; 0 before.
    pub seq: u64,
    pub by: Author,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub item_id: Option<String>,
    pub kind: ChangeKind,
    pub fields: BTreeMap<String, (Value, Value)>,
    pub at: DateTime<Utc>,
}

impl Change {
    /// A change with no fields yet.
    pub fn new(by: &Author, item_id: Option<&str>, kind: ChangeKind, at: DateTime<Utc>) -> Change {
        Change {
            seq: 0,
            by: by.clone(),
            item_id: item_id.map(str::to_string),
            kind,
            fields: BTreeMap::new(),
            at,
        }
    }

    pub fn with_field(mut self, name: &str, old: Value, new: Value) -> Change {
        self.fields.insert(name.to_string(), (old, new));
        self
    }
}
