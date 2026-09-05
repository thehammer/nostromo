//! Issue-tracker provider abstraction and the `ticket` view's data model (W4 —
//! curated-agent-views).
//!
//! `Ticket` is what any registered [`TicketProvider`] produces; Jira is the
//! only provider registered in v1 ([`jira::JiraProvider`]). The provider is a
//! request field (D1 of the W4 plan), not a view type, so Linear/GitHub
//! Issues can register a second provider later without a new
//! `PaneContentWire` variant.
//!
//! Section derivation ([`derive_sections`]) and requested-section resolution
//! ([`resolve_section`]) are pure — no network, no filesystem beyond the
//! alias table in [`config`] — which is what the PRD's anchoring criterion
//! rests on.

pub mod config;
pub mod jira;

use async_trait::async_trait;

use crate::ipc::protocol::{MdBlock, MdSpan};

// ── data model ───────────────────────────────────────────────────────────────

/// A fetched ticket, provider-agnostic.
#[derive(Debug, Clone, PartialEq)]
pub struct Ticket {
    pub provider: String,
    pub key: String,
    pub summary: String,
    pub status: String,
    pub assignee: Option<String>,
    pub url: String,
    /// Blocks before the first heading form a `"description"` section; each
    /// subsequent heading starts a new, alias-resolved section (D4).
    pub sections: Vec<TicketSection>,
    /// Chronological, 1-indexed — each addressable as `comment:<index>`.
    pub comments: Vec<TicketComment>,
}

/// One section of a ticket's description — either the leading `"description"`
/// section (no heading of its own) or a heading-derived, alias-resolved
/// section.
#[derive(Debug, Clone, PartialEq)]
pub struct TicketSection {
    /// Canonical, alias-resolved name (e.g. `"description"`,
    /// `"acceptance_criteria"`).
    pub name: String,
    /// The heading's own rendered spans. `None` for the leading section.
    pub heading: Option<Vec<MdSpan>>,
    pub blocks: Vec<MdBlock>,
}

/// One comment on a ticket.
#[derive(Debug, Clone, PartialEq)]
pub struct TicketComment {
    /// 1-based; addressable as `comment:<index>`.
    pub index: u32,
    pub author: String,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub blocks: Vec<MdBlock>,
}

// ── errors ───────────────────────────────────────────────────────────────────

/// Stable, machine-readable failure modes for the ticket provider surface.
/// Mirrors `ApplyLayoutError`'s style — a closed set with a `code()` mapping
/// the wire uses, plus a human-readable detail message an agent can act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TicketError {
    /// `provider` named something not in the registry. Carries the
    /// registry's actual supported-provider list so the refusal is
    /// actionable rather than a dead end.
    UnsupportedProvider { supported: Vec<String> },
    /// `provider` is registered but has no resolved credentials.
    ProviderUnconfigured { message: String },
    /// The provider's backend has no such ticket (e.g. a 404 from Jira).
    UnknownTicket,
    /// A requested anchor/emphasis section name resolved to nothing in the
    /// fetched ticket. Carries the section names that *do* exist.
    UnknownSection { available: Vec<String> },
    /// The provider ran but failed for a reason that isn't one of the above
    /// (network error, non-404 non-2xx status, malformed response).
    FetchFailed(String),
}

impl TicketError {
    /// The stable snake_case code for the wire.
    pub fn code(&self) -> &'static str {
        match self {
            TicketError::UnsupportedProvider { .. } => "unsupported_provider",
            TicketError::ProviderUnconfigured { .. } => "provider_unconfigured",
            TicketError::UnknownTicket => "unknown_ticket",
            TicketError::UnknownSection { .. } => "unknown_section",
            TicketError::FetchFailed(_) => "fetch_failed",
        }
    }

    /// A human-readable, actionable message — what actually gets surfaced to
    /// the calling agent alongside `code()`.
    pub fn detail_message(&self) -> String {
        match self {
            TicketError::UnsupportedProvider { supported } => format!(
                "unsupported provider — this deployment supports: {}",
                supported.join(", ")
            ),
            TicketError::ProviderUnconfigured { message } => message.clone(),
            TicketError::UnknownTicket => "no such ticket".to_string(),
            TicketError::UnknownSection { available } => format!(
                "unknown section — available sections: {}",
                available.join(", ")
            ),
            TicketError::FetchFailed(msg) => msg.clone(),
        }
    }
}

// ── provider trait + registry ─────────────────────────────────────────────────

/// One issue-tracker backend. `jira` is the only implementation in v1
/// ([`jira::JiraProvider`]).
#[async_trait]
pub trait TicketProvider: Send + Sync {
    /// The registry key this provider answers to (e.g. `"jira"`).
    fn name(&self) -> &'static str;
    /// Whether this deployment can actually serve requests — credentials
    /// resolved. Separate from registration: `jira` is always registered but
    /// may be unconfigured, and those are two different refusals
    /// (`unsupported_provider` vs `provider_unconfigured`).
    fn is_configured(&self) -> bool;
    /// The actionable message for `provider_unconfigured`, when
    /// `is_configured()` is false. Computed once at construction.
    fn unconfigured_message(&self) -> String;
    /// Fetch one ticket by key.
    async fn fetch(&self, key: &str) -> Result<Ticket, TicketError>;
}

/// Name-keyed registry of [`TicketProvider`]s. Closed: a name not registered
/// is `unsupported_provider`, never a fall-through to raw text.
#[derive(Default)]
pub struct TicketRegistry {
    providers: std::collections::HashMap<&'static str, std::sync::Arc<dyn TicketProvider>>,
}

impl TicketRegistry {
    pub fn new() -> Self {
        Self {
            providers: std::collections::HashMap::new(),
        }
    }

    pub fn register(&mut self, provider: std::sync::Arc<dyn TicketProvider>) {
        self.providers.insert(provider.name(), provider);
    }

    /// Resolve `name` to a configured provider, or the specific refusal.
    pub fn get(&self, name: &str) -> Result<std::sync::Arc<dyn TicketProvider>, TicketError> {
        match self.providers.get(name) {
            None => Err(TicketError::UnsupportedProvider {
                supported: self.supported_names(),
            }),
            Some(p) if !p.is_configured() => Err(TicketError::ProviderUnconfigured {
                message: p.unconfigured_message(),
            }),
            Some(p) => Ok(std::sync::Arc::clone(p)),
        }
    }

    /// Every registered provider name, sorted — used both by
    /// `unsupported_provider`'s message and by tests.
    pub fn supported_names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.providers.keys().map(|s| s.to_string()).collect();
        names.sort();
        names
    }
}

// ── in-memory TTL cache ───────────────────────────────────────────────────────

/// Short-TTL `(provider, key) -> Ticket` cache so a repeatedly-shown or
/// daemon-repainted ticket pane doesn't hit the backend on every paint (D5).
/// Not persisted across restarts.
pub struct TicketCache {
    entries:
        std::sync::Mutex<std::collections::HashMap<(String, String), (Ticket, std::time::Instant)>>,
    ttl: std::time::Duration,
}

impl TicketCache {
    pub fn new(ttl: std::time::Duration) -> Self {
        Self {
            entries: std::sync::Mutex::new(std::collections::HashMap::new()),
            ttl,
        }
    }

    /// A still-fresh cached ticket for `(provider, key)`, if any.
    pub fn get(&self, provider: &str, key: &str) -> Option<Ticket> {
        let entries = self.entries.lock().unwrap();
        let (ticket, fetched_at) = entries.get(&(provider.to_string(), key.to_string()))?;
        if fetched_at.elapsed() < self.ttl {
            Some(ticket.clone())
        } else {
            None
        }
    }

    pub fn put(&self, provider: &str, key: &str, ticket: Ticket) {
        let mut entries = self.entries.lock().unwrap();
        entries.insert(
            (provider.to_string(), key.to_string()),
            (ticket, std::time::Instant::now()),
        );
    }
}

impl Default for TicketCache {
    fn default() -> Self {
        Self::new(std::time::Duration::from_secs(60))
    }
}

// ── section derivation (D4) ───────────────────────────────────────────────────

/// The name every ticket's leading section carries, before its first heading.
pub const DESCRIPTION_SECTION: &str = "description";

/// Prefix a requested/derived name carries when it addresses a comment by
/// 1-based index rather than a heading-derived section (D4).
pub const COMMENT_ANCHOR_PREFIX: &str = "comment:";

/// Split a ticket description's blocks into sections: everything before the
/// first heading is `"description"`; each heading afterward starts a new
/// section named after that heading's alias-resolved, normalized text. Pure
/// — no network, no filesystem.
pub fn derive_sections(blocks: Vec<MdBlock>, aliases: &config::AliasTable) -> Vec<TicketSection> {
    let mut sections = Vec::new();
    let mut name = DESCRIPTION_SECTION.to_string();
    let mut heading: Option<Vec<MdSpan>> = None;
    let mut acc: Vec<MdBlock> = Vec::new();

    for block in blocks {
        if let MdBlock::Heading { ref spans, .. } = block {
            sections.push(TicketSection {
                name,
                heading,
                blocks: std::mem::take(&mut acc),
            });
            name = canonical_section_name(&plain_text(spans), aliases);
            heading = Some(spans.clone());
            continue;
        }
        acc.push(block);
    }
    sections.push(TicketSection {
        name,
        heading,
        blocks: acc,
    });
    sections
}

/// Normalize `raw` (lowercase, non-alphanumeric runs collapsed to a single
/// `_`, trimmed) then resolve it against `aliases` — the single function
/// used both when deriving a section's name from a heading and when
/// resolving a caller's requested anchor/emphasis name, so the two can never
/// disagree about what a name means.
pub fn canonical_section_name(raw: &str, aliases: &config::AliasTable) -> String {
    aliases.resolve(&normalize_name(raw))
}

/// Lowercase, collapse non-alphanumeric runs to a single `_`, trim. Exposed
/// `pub(crate)` so `config::AliasTable::resolve` can normalize its own YAML
/// variants the same way before comparing — one normalization rule, used on
/// both sides of the alias lookup.
pub(crate) fn normalize_name(raw: &str) -> String {
    let mut out = String::new();
    let mut last_was_sep = true; // suppress a leading separator
    for ch in raw.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            last_was_sep = false;
        } else if !last_was_sep {
            out.push('_');
            last_was_sep = true;
        }
    }
    while out.ends_with('_') {
        out.pop();
    }
    out
}

fn plain_text(spans: &[MdSpan]) -> String {
    spans.iter().map(plain_text_span).collect()
}

fn plain_text_span(span: &MdSpan) -> String {
    match span {
        MdSpan::Text { text } | MdSpan::Code { text } => text.clone(),
        MdSpan::Emph { spans } | MdSpan::Strong { spans } | MdSpan::Strike { spans } => {
            plain_text(spans)
        }
        MdSpan::Link { spans, .. } => plain_text(spans),
        MdSpan::Image { alt, .. } => alt.clone(),
    }
}

/// Whether `requested` (a raw `Anchor::Section`/`Emphasis::Section` name)
/// resolves against `sections`/`comments`. `"comment:<n>"` addresses a
/// 1-based comment index directly; anything else is alias-normalized and
/// matched against `sections`' canonical names. Returns the specific refusal
/// — naming every section that *does* exist — when it doesn't.
pub fn resolve_section(
    sections: &[TicketSection],
    comments: &[TicketComment],
    requested: &str,
    aliases: &config::AliasTable,
) -> Result<(), TicketError> {
    if let Some(rest) = requested.strip_prefix(COMMENT_ANCHOR_PREFIX) {
        if let Ok(n) = rest.parse::<u32>() {
            if comments.iter().any(|c| c.index == n) {
                return Ok(());
            }
        }
        return Err(unknown_section_error(sections));
    }

    let canonical = canonical_section_name(requested, aliases);
    if sections.iter().any(|s| s.name == canonical) {
        Ok(())
    } else {
        Err(unknown_section_error(sections))
    }
}

fn unknown_section_error(sections: &[TicketSection]) -> TicketError {
    TicketError::UnknownSection {
        available: sections.iter().map(|s| s.name.clone()).collect(),
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// A small alias table for tests that don't want to touch the on-disk
    /// loader (that's `config.rs`'s own job) — just enough to exercise
    /// alias resolution.
    fn test_aliases() -> config::AliasTable {
        serde_yaml::from_str(
            r#"
aliases:
  acceptance_criteria:
    - "Acceptance Criteria"
    - "AC"
"#,
        )
        .unwrap()
    }

    fn sample_ticket() -> Ticket {
        Ticket {
            provider: "jira".into(),
            key: "X-1".into(),
            summary: "s".into(),
            status: "Open".into(),
            assignee: None,
            url: "".into(),
            sections: vec![],
            comments: vec![],
        }
    }

    // ── 1. derive_sections ───────────────────────────────────────────────────

    #[test]
    fn derive_sections_content_before_first_heading_is_the_description_section() {
        let aliases = test_aliases();
        let blocks = vec![MdBlock::Paragraph {
            spans: vec![MdSpan::Text {
                text: "intro text".into(),
            }],
        }];
        let sections = derive_sections(blocks.clone(), &aliases);
        assert_eq!(sections.len(), 1);
        assert_eq!(sections[0].name, DESCRIPTION_SECTION);
        assert!(sections[0].heading.is_none());
        assert_eq!(sections[0].blocks, blocks);
    }

    #[test]
    fn derive_sections_each_heading_starts_a_new_alias_resolved_section() {
        let aliases = test_aliases();
        let blocks = vec![
            MdBlock::Paragraph {
                spans: vec![MdSpan::Text {
                    text: "intro".into(),
                }],
            },
            MdBlock::Heading {
                level: 2,
                spans: vec![MdSpan::Text { text: "AC".into() }],
            },
            MdBlock::Paragraph {
                spans: vec![MdSpan::Text {
                    text: "criteria body".into(),
                }],
            },
        ];
        let sections = derive_sections(blocks, &aliases);
        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].name, DESCRIPTION_SECTION);
        assert_eq!(
            sections[0].blocks,
            vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Text {
                    text: "intro".into()
                }]
            }]
        );
        assert_eq!(
            sections[1].name, "acceptance_criteria",
            "the 'AC' heading must alias-resolve"
        );
        assert!(sections[1].heading.is_some());
        assert_eq!(
            sections[1].blocks,
            vec![MdBlock::Paragraph {
                spans: vec![MdSpan::Text {
                    text: "criteria body".into()
                }]
            }]
        );
    }

    #[test]
    fn derive_sections_with_only_a_heading_and_no_leading_content_still_yields_an_empty_description(
    ) {
        let aliases = test_aliases();
        let blocks = vec![
            MdBlock::Heading {
                level: 2,
                spans: vec![MdSpan::Text { text: "AC".into() }],
            },
            MdBlock::Paragraph {
                spans: vec![MdSpan::Text {
                    text: "criteria".into(),
                }],
            },
        ];
        let sections = derive_sections(blocks, &aliases);
        assert_eq!(sections.len(), 2);
        assert_eq!(sections[0].name, DESCRIPTION_SECTION);
        assert!(
            sections[0].blocks.is_empty(),
            "no content before the first heading must yield an empty, not omitted, description \
             section"
        );
        assert_eq!(sections[1].name, "acceptance_criteria");
    }

    // ── 2. canonical_section_name ─────────────────────────────────────────────

    #[test]
    fn canonical_section_name_normalizes_case_punctuation_and_whitespace() {
        let aliases = config::AliasTable::default();
        assert_eq!(
            canonical_section_name("  Some Heading!! ", &aliases),
            "some_heading"
        );
        assert_eq!(
            canonical_section_name("Some-Heading", &aliases),
            "some_heading"
        );
        assert_eq!(
            canonical_section_name("SOME   heading", &aliases),
            "some_heading"
        );
    }

    #[test]
    fn canonical_section_name_resolves_every_documented_alias_variant_to_acceptance_criteria() {
        let aliases = test_aliases();
        for variant in [
            "Acceptance Criteria",
            "AC",
            "ac",
            "  ac  ",
            "acceptance-criteria",
        ] {
            assert_eq!(
                canonical_section_name(variant, &aliases),
                "acceptance_criteria",
                "variant {variant:?} must resolve to acceptance_criteria"
            );
        }
    }

    #[test]
    fn canonical_section_name_leaves_a_name_with_no_matching_alias_unchanged_but_normalized() {
        let aliases = test_aliases();
        assert_eq!(
            canonical_section_name("Random Heading", &aliases),
            "random_heading"
        );
    }

    // ── 3. resolve_section ────────────────────────────────────────────────────

    fn sample_sections() -> Vec<TicketSection> {
        vec![
            TicketSection {
                name: DESCRIPTION_SECTION.to_string(),
                heading: None,
                blocks: vec![],
            },
            TicketSection {
                name: "acceptance_criteria".to_string(),
                heading: Some(vec![]),
                blocks: vec![],
            },
        ]
    }

    fn sample_comments() -> Vec<TicketComment> {
        vec![TicketComment {
            index: 1,
            author: "alice".into(),
            created_at: chrono::Utc::now(),
            blocks: vec![],
        }]
    }

    #[test]
    fn resolve_section_succeeds_for_a_known_section_name_and_its_alias() {
        let aliases = test_aliases();
        let sections = sample_sections();
        let comments = sample_comments();
        assert!(resolve_section(&sections, &comments, "acceptance_criteria", &aliases).is_ok());
        assert!(
            resolve_section(&sections, &comments, "AC", &aliases).is_ok(),
            "a raw alias variant must resolve exactly like the canonical name"
        );
    }

    #[test]
    fn resolve_section_refuses_an_unknown_name_listing_every_existing_section() {
        let aliases = test_aliases();
        let sections = sample_sections();
        let comments = sample_comments();
        let err = resolve_section(&sections, &comments, "does_not_exist", &aliases).unwrap_err();
        match err {
            TicketError::UnknownSection { available } => {
                assert_eq!(
                    available,
                    vec![
                        DESCRIPTION_SECTION.to_string(),
                        "acceptance_criteria".to_string()
                    ]
                );
            }
            other => panic!("expected UnknownSection, got {other:?}"),
        }
    }

    #[test]
    fn resolve_section_resolves_an_in_range_comment_index() {
        let aliases = test_aliases();
        let sections = sample_sections();
        let comments = sample_comments();
        assert!(resolve_section(&sections, &comments, "comment:1", &aliases).is_ok());
    }

    #[test]
    fn resolve_section_refuses_an_out_of_range_comment_index() {
        let aliases = test_aliases();
        let sections = sample_sections();
        let comments = sample_comments();
        let err = resolve_section(&sections, &comments, "comment:2", &aliases).unwrap_err();
        assert!(
            matches!(err, TicketError::UnknownSection { .. }),
            "an out-of-range comment index must refuse the same way an unknown section name does"
        );
    }

    #[test]
    fn resolve_section_refuses_a_non_numeric_comment_suffix_rather_than_panicking() {
        let aliases = test_aliases();
        let sections = sample_sections();
        let comments = sample_comments();
        let err =
            resolve_section(&sections, &comments, "comment:not-a-number", &aliases).unwrap_err();
        assert!(matches!(err, TicketError::UnknownSection { .. }));
    }

    // ── 4. TicketRegistry ─────────────────────────────────────────────────────

    struct StubProvider {
        configured: bool,
    }

    #[async_trait]
    impl TicketProvider for StubProvider {
        fn name(&self) -> &'static str {
            "jira"
        }
        fn is_configured(&self) -> bool {
            self.configured
        }
        fn unconfigured_message(&self) -> String {
            "stub unconfigured".to_string()
        }
        async fn fetch(&self, _key: &str) -> Result<Ticket, TicketError> {
            Ok(sample_ticket())
        }
    }

    #[test]
    fn registry_get_on_an_unregistered_name_is_unsupported_provider_naming_every_registered_provider(
    ) {
        let mut reg = TicketRegistry::new();
        reg.register(Arc::new(StubProvider { configured: true }));
        let err = reg.get("linear").err().unwrap();
        assert_eq!(
            err,
            TicketError::UnsupportedProvider {
                supported: vec!["jira".to_string()]
            }
        );
    }

    #[test]
    fn registry_get_on_a_registered_but_unconfigured_provider_is_provider_unconfigured() {
        let mut reg = TicketRegistry::new();
        reg.register(Arc::new(StubProvider { configured: false }));
        let err = reg.get("jira").err().unwrap();
        assert_eq!(
            err,
            TicketError::ProviderUnconfigured {
                message: "stub unconfigured".to_string()
            }
        );
    }

    #[test]
    fn registry_get_on_a_configured_provider_resolves() {
        let mut reg = TicketRegistry::new();
        reg.register(Arc::new(StubProvider { configured: true }));
        assert!(reg.get("jira").is_ok());
    }

    #[test]
    fn registry_supported_names_is_sorted_and_lists_every_registered_provider() {
        let mut reg = TicketRegistry::new();
        reg.register(Arc::new(StubProvider { configured: true }));
        assert_eq!(reg.supported_names(), vec!["jira".to_string()]);
    }

    // ── 5. TicketError::code() ────────────────────────────────────────────────

    #[test]
    fn ticket_error_code_is_stable_for_every_variant() {
        assert_eq!(
            TicketError::UnsupportedProvider { supported: vec![] }.code(),
            "unsupported_provider"
        );
        assert_eq!(
            TicketError::ProviderUnconfigured {
                message: "x".into()
            }
            .code(),
            "provider_unconfigured"
        );
        assert_eq!(TicketError::UnknownTicket.code(), "unknown_ticket");
        assert_eq!(
            TicketError::UnknownSection { available: vec![] }.code(),
            "unknown_section"
        );
        assert_eq!(TicketError::FetchFailed("x".into()).code(), "fetch_failed");
    }

    // ── extra: TicketCache TTL expiry (D5) ────────────────────────────────────
    // Not one of the five listed items, but TicketCache is defined in this
    // module and its expiry behavior underlies the dispatch-level TTL test in
    // apply_layout.rs — worth a direct, deterministic unit test here too.

    #[test]
    fn cache_returns_the_ticket_before_ttl_expiry_and_none_after() {
        let cache = TicketCache::new(std::time::Duration::from_millis(40));
        let ticket = sample_ticket();
        cache.put("jira", "X-1", ticket.clone());
        assert_eq!(cache.get("jira", "X-1"), Some(ticket));
        std::thread::sleep(std::time::Duration::from_millis(120));
        assert_eq!(
            cache.get("jira", "X-1"),
            None,
            "an entry older than the TTL must no longer be served"
        );
    }

    #[test]
    fn cache_get_is_none_for_a_provider_key_pair_never_put() {
        let cache = TicketCache::new(std::time::Duration::from_secs(60));
        assert_eq!(cache.get("jira", "NEVER-1"), None);
    }
}
