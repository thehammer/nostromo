//! The report model and how it renders: `report.md` and the `MdBlock`s a
//! pane paints.
//!
//! The daemon owns every link, label, date, count and the footer (A4). Text
//! that came from the model or from a news item is cleaned to one line
//! before it gets here and is escaped here, so it can never become a link,
//! an HTML tag or a heading.
//!
//! Order: opener, the tight or uncurated label, picks (or the quiet line),
//! Also in the news, Also noted, the uncurated list, footer.

use std::path::Path;

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::huey::budget::Mode;
use crate::huey::context::ContextSource;
use crate::huey::setup::{InterestsStatus, SetupScan};
use crate::huey::store::VerdictKind;
use crate::ipc::protocol::{
    DocAction, DocBanner, DocBannerLevel, MdBlock, MdSpan, PaneContentWire,
};

pub const TIGHT_LINE: &str = "Short report: budget is tight today.";
pub const QUIET_LINE: &str = "Nothing that touches your work today.";
pub const UNCURATED_LINE: &str = "Uncurated: budget is critical, so no model ran today.";
pub const AIN_LABEL: &str = "Also in the news (not tied to your work)";
/// Headlines an uncurated report lists before "and N more" (V4).
pub const UNCURATED_CAP: usize = 20;
/// Footer drops shown, at most.
pub const FOOTER_DROPS: usize = 5;
/// Words the footer may use (AC12, D2).
pub const FOOTER_MAX_WORDS: usize = 100;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Link {
    pub title: String,
    pub url: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PickCheck {
    Checked { text: String },
    ToCheck { text: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pick {
    /// Every item the pick covers (the story and its other coverage).
    pub item_ids: Vec<String>,
    pub headline: String,
    pub what_happened: String,
    /// Project id from the digest.
    pub project: String,
    /// As the digest names it.
    pub project_name: String,
    pub for_line: String,
    /// Digest anchor ids the pick cites (the evidence for its "For" line).
    #[serde(default)]
    pub anchors: Vec<String>,
    pub check: PickCheck,
    /// The best source's link.
    pub link: Link,
    pub also_covered_by: Vec<Link>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub follow_up_of: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub whats_new: Option<String>,
}

/// The Also-in-the-news line. No "For" and no "Check": it is not tied to
/// any project (AC40).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AinLine {
    pub item_id: String,
    pub headline: String,
    pub what_happened: String,
    pub link: Link,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NotedLine {
    pub item_ids: Vec<String>,
    pub line: String,
    /// Interest id from the digest (`i3`).
    pub interest: String,
    pub link: Link,
}

/// One headline of an uncurated (critical) report.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HeadlineLine {
    pub item_id: String,
    pub source: String,
    pub link: Link,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct UncuratedList {
    /// At most [`UNCURATED_CAP`], newest first.
    pub lines: Vec<HeadlineLine>,
    /// First-party items beyond the cap.
    pub more: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FailedSource {
    pub name: String,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FooterDrop {
    pub item_id: String,
    pub title: String,
    pub reason: String,
}

/// What the footer says (A7). Rendered by [`footer_text`].
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Footer {
    /// Items fetched in the window.
    pub looked_at: usize,
    /// Sources that answered (ok or quiet).
    pub sources_read: usize,
    /// First-party sources that answered.
    pub read_in_full: Vec<String>,
    /// Sources that answered with nothing new.
    pub quiet: Vec<String>,
    pub failed: Vec<FailedSource>,
    /// In-flight project names, digest order.
    pub in_flight: Vec<String>,
    /// Model drops first, then hard-ignore drops; never an item shown
    /// anywhere. Rendered at most [`FOOTER_DROPS`].
    pub dropped: Vec<FooterDrop>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ain_skip_reason: Option<String>,
    #[serde(default)]
    pub posture_unavailable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Report {
    pub date: NaiveDate,
    pub version: u32,
    pub mode: Mode,
    /// The model's opener, after the daemon's date prefix. Empty when uncurated.
    pub opener_gist: String,
    pub picks: Vec<Pick>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub also_in_the_news: Option<AinLine>,
    #[serde(default)]
    pub also_noted: Vec<NotedLine>,
    /// Present only for an uncurated (critical) report.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub uncurated: Option<UncuratedList>,
    pub footer: Footer,
}

impl Report {
    pub fn is_uncurated(&self) -> bool {
        self.uncurated.is_some()
    }

    /// Every item id shown anywhere in the report.
    pub fn shown_ids(&self) -> Vec<&str> {
        let mut out: Vec<&str> = Vec::new();
        for p in &self.picks {
            out.extend(p.item_ids.iter().map(String::as_str));
        }
        if let Some(a) = &self.also_in_the_news {
            out.push(&a.item_id);
        }
        for n in &self.also_noted {
            out.extend(n.item_ids.iter().map(String::as_str));
        }
        if let Some(u) = &self.uncurated {
            out.extend(u.lines.iter().map(|l| l.item_id.as_str()));
        }
        out
    }
}

/// `Monday, Oct 26.`
pub fn date_prefix(date: NaiveDate) -> String {
    format!("{}.", date.format("%A, %b %-d"))
}

/// The pane and document title. Always carries the date (AC31).
pub fn title(date: NaiveDate, version: u32) -> String {
    let base = format!("Huey, {}", date.format("%a %b %-d, %Y"));
    if version > 1 {
        format!("{base} (v{version})")
    } else {
        base
    }
}

/// Extra paragraphs a document adds around the stored report: the version
/// line after the opener, and a verdict line after each pick. Never part of
/// `report.md`.
#[derive(Debug, Clone, Default)]
pub struct DocExtras {
    /// Markdown paragraph placed right after the opener.
    pub after_opener: Option<String>,
    /// Markdown paragraph placed after pick `n` (index `n - 1`).
    pub after_pick: Vec<Option<String>>,
}

/// `report.md`.
pub fn render_markdown(report: &Report) -> String {
    render_markdown_with(report, &DocExtras::default())
}

/// The report's markdown with a document's extra paragraphs in place.
pub fn render_markdown_with(report: &Report, extras: &DocExtras) -> String {
    let mut out = String::new();
    let para = |out: &mut String, text: &str| {
        out.push_str(text);
        out.push_str("\n\n");
    };

    let opener = if report.opener_gist.trim().is_empty() {
        date_prefix(report.date)
    } else {
        format!("{} {}", date_prefix(report.date), esc(&report.opener_gist))
    };
    para(&mut out, &opener);
    if let Some(line) = &extras.after_opener {
        para(&mut out, line);
    }
    if report.is_uncurated() {
        para(&mut out, UNCURATED_LINE);
    } else if report.mode == Mode::Tight {
        para(&mut out, TIGHT_LINE);
    }

    if !report.is_uncurated() {
        if report.picks.is_empty() {
            para(&mut out, QUIET_LINE);
        }
        for (n, pick) in report.picks.iter().enumerate() {
            out.push_str(&format!("### {}. {}\n\n", n + 1, esc(&pick.headline)));
            para(
                &mut out,
                &format!("{} {}", esc(&pick.what_happened), link(&pick.link)),
            );
            if let (Some(_), Some(new)) = (&pick.follow_up_of, &pick.whats_new) {
                para(&mut out, &format!("**What's new:** {}", esc(new)));
            }
            para(
                &mut out,
                &format!(
                    "**For {}:** {}",
                    esc(&pick.project_name),
                    esc(&pick.for_line)
                ),
            );
            let check = match &pick.check {
                PickCheck::Checked { text } => format!("**Checked:** {}", esc(text)),
                PickCheck::ToCheck { text } => format!("**To check:** {}", esc(text)),
            };
            para(&mut out, &check);
            if !pick.also_covered_by.is_empty() {
                let others: Vec<String> = pick.also_covered_by.iter().map(link).collect();
                para(&mut out, &format!("Also covered by {}", others.join(", ")));
            }
            if let Some(Some(extra)) = extras.after_pick.get(n) {
                para(&mut out, extra);
            }
        }
    }

    if let Some(ain) = &report.also_in_the_news {
        out.push_str(&format!("### {AIN_LABEL}\n\n"));
        para(
            &mut out,
            &format!(
                "**{}.** {} {}",
                esc(ain.headline.trim_end_matches('.')),
                esc(&ain.what_happened),
                link(&ain.link)
            ),
        );
    }

    if report.mode != Mode::Tight && !report.also_noted.is_empty() {
        out.push_str("### Also noted\n\n");
        for n in &report.also_noted {
            out.push_str(&format!("- {} {}\n", esc(&n.line), link(&n.link)));
        }
        out.push('\n');
    }

    if let Some(list) = &report.uncurated {
        out.push_str("### First-party headlines\n\n");
        for l in &list.lines {
            out.push_str(&format!("- {} ({})\n", link(&l.link), esc(&l.source)));
        }
        if list.more > 0 {
            out.push_str(&format!("- and {} more (first-party)\n", list.more));
        }
        if list.lines.is_empty() {
            out.push_str("- No new first-party items.\n");
        }
        out.push('\n');
    }

    out.push_str("---\n\n");
    out.push_str(&esc(&footer_text(&report.footer)));
    out.push('\n');
    out
}

/// The pane's blocks for `report`, with a document's extras.
pub fn render_blocks_with(report: &Report, extras: &DocExtras) -> Vec<MdBlock> {
    crate::markdown_blocks::markdown_to_blocks(&render_markdown_with(report, extras))
}

/// The pane's blocks for `report`.
pub fn render_blocks(report: &Report) -> Vec<MdBlock> {
    crate::markdown_blocks::markdown_to_blocks(&render_markdown(report))
}

/// Word counts as the caps measure them (D2): the whole report, the body
/// (everything but the footer) and the footer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WordCounts {
    pub total: usize,
    pub body: usize,
    pub footer: usize,
}

pub fn word_counts(report: &Report) -> WordCounts {
    let total = blocks_words(&render_blocks(report));
    let footer = words(&footer_text(&report.footer));
    WordCounts {
        total,
        body: total.saturating_sub(footer),
        footer,
    }
}

/// Words in `text`: whitespace-separated runs.
pub fn words(text: &str) -> usize {
    text.split_whitespace().count()
}

/// Visible words in rendered blocks (link URLs are not words).
pub fn blocks_words(blocks: &[MdBlock]) -> usize {
    let mut text = String::new();
    for b in blocks {
        block_text(b, &mut text);
    }
    words(&text)
}

fn block_text(block: &MdBlock, out: &mut String) {
    match block {
        MdBlock::Paragraph { spans } | MdBlock::Heading { spans, .. } => spans_text(spans, out),
        MdBlock::CodeBlock { text, .. } => out.push_str(text),
        MdBlock::List { items, .. } => items.iter().flatten().for_each(|b| block_text(b, out)),
        MdBlock::Quote { blocks } => blocks.iter().for_each(|b| block_text(b, out)),
        MdBlock::Table { header, rows } => {
            header.iter().for_each(|c| spans_text(c, out));
            rows.iter().flatten().for_each(|c| spans_text(c, out));
        }
        MdBlock::Rule => {}
    }
    out.push(' ');
}

fn spans_text(spans: &[MdSpan], out: &mut String) {
    for s in spans {
        match s {
            MdSpan::Text { text } | MdSpan::Code { text } => out.push_str(text),
            MdSpan::Emph { spans }
            | MdSpan::Strong { spans }
            | MdSpan::Strike { spans }
            | MdSpan::Link { spans, .. } => spans_text(spans, out),
            MdSpan::Image { alt, .. } => out.push_str(alt),
        }
    }
    out.push(' ');
}

/// The footer as plain text, held to [`FOOTER_MAX_WORDS`]: drop titles are
/// shortened, then fewer drops are shown, before anything else is cut.
pub fn footer_text(f: &Footer) -> String {
    let shown = f.dropped.len().min(FOOTER_DROPS);
    for drops in (0..=shown).rev() {
        for title_words in [12, 6, 3] {
            let text = footer_with(f, drops, title_words);
            if words(&text) <= FOOTER_MAX_WORDS {
                return text;
            }
        }
    }
    let text = footer_with(f, 0, 3);
    let cut: Vec<&str> = text.split_whitespace().take(FOOTER_MAX_WORDS - 1).collect();
    format!("{} …", cut.join(" "))
}

fn footer_with(f: &Footer, drops: usize, title_words: usize) -> String {
    let list = |names: &[String]| names.join(", ");
    let mut parts = vec![format!(
        "Looked at {} items from {} sources.",
        f.looked_at, f.sources_read
    )];
    if !f.read_in_full.is_empty() {
        parts.push(format!("Read in full: {}.", list(&f.read_in_full)));
    }
    if !f.quiet.is_empty() {
        parts.push(format!("No new items: {}.", list(&f.quiet)));
    }
    if f.failed.is_empty() {
        parts.push("Failed: none.".to_string());
    } else {
        let failed: Vec<String> = f
            .failed
            .iter()
            .map(|s| format!("{} ({})", s.name, s.reason))
            .collect();
        parts.push(format!("Failed: {}.", failed.join(", ")));
    }
    if f.in_flight.is_empty() {
        parts.push("In flight: none.".to_string());
    } else {
        parts.push(format!("In flight: {}.", list(&f.in_flight)));
    }
    if drops > 0 {
        let shown: Vec<String> = f
            .dropped
            .iter()
            .take(drops)
            .map(|d| format!("{} ({})", shorten(&d.title, title_words), d.reason))
            .collect();
        parts.push(format!("Dropped: {}.", shown.join("; ")));
    }
    if let Some(reason) = &f.ain_skip_reason {
        parts.push(format!(
            "No Also-in-the-news line: {}.",
            reason.trim_end_matches('.')
        ));
    }
    if f.posture_unavailable {
        parts.push("Budget posture unavailable.".to_string());
    }
    parts.join(" ")
}

fn shorten(text: &str, max_words: usize) -> String {
    let all: Vec<&str> = text.split_whitespace().collect();
    if all.len() <= max_words {
        all.join(" ")
    } else {
        format!("{}…", all[..max_words].join(" "))
    }
}

/// `[title](<url>)`: the title escaped, the URL re-serialised so it carries
/// no space, angle bracket or quote.
fn link(l: &Link) -> String {
    let url = url::Url::parse(&l.url)
        .ok()
        .filter(|u| matches!(u.scheme(), "http" | "https"))
        .map(|u| u.to_string());
    match url {
        Some(url) => format!("[{}](<{url}>)", esc(&l.title)),
        None => esc(&l.title),
    }
}

/// Escape everything that could turn untrusted text into markup: links,
/// autolinks, HTML, emphasis, code, headings.
pub fn esc(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if matches!(
            c,
            '\\' | '[' | ']' | '(' | ')' | '<' | '>' | '*' | '_' | '`' | '#' | '!' | '|' | '~'
        ) {
            out.push('\\');
        }
        out.push(c);
    }
    // A leading `-`, `+` or `=` (or `1.`) would start a list or a heading.
    if out.starts_with(['-', '+', '=']) {
        out.insert(0, '\\');
    }
    let digits = out.chars().take_while(char::is_ascii_digit).count();
    if digits > 0 && out[digits..].starts_with('.') {
        out.insert(digits, '\\');
    }
    out
}

// ── Documents ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BannerLevel {
    Info,
    Warning,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Banner {
    pub level: BannerLevel,
    pub text: String,
}

/// Why today's report is not the one shown (AC31). Budget is never a reason
/// (V6): a critical day still produces a headline report.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MissingReason {
    /// Not due yet, running, or waiting for its one retry.
    Pending,
    Asleep,
    FetchFailed,
    ModelFailed,
    /// The report was made but could not be saved.
    WriteFailed,
}

impl MissingReason {
    pub fn text(self) -> &'static str {
        match self {
            MissingReason::Pending => "it is not ready yet",
            MissingReason::Asleep => {
                "the machine was asleep or the daemon was not running at report time"
            }
            MissingReason::FetchFailed => "fetching the news failed",
            MissingReason::ModelFailed => "the model run failed",
            MissingReason::WriteFailed => "the report could not be saved",
        }
    }

    /// Waiting is information; anything else is a warning.
    fn banner_level(self) -> BannerLevel {
        match self {
            MissingReason::Pending => BannerLevel::Info,
            _ => BannerLevel::Warning,
        }
    }
}

/// The banner for a report dated `shown` when today is `today`: `None` for
/// today's own report, otherwise one naming the report's date and why
/// today's is missing.
pub fn banner_for(shown: NaiveDate, today: NaiveDate, reason: MissingReason) -> Option<Banner> {
    if shown == today {
        return None;
    }
    Some(Banner {
        level: reason.banner_level(),
        text: format!(
            "This is the report from {}. Today's report is missing: {}.",
            shown.format("%A, %b %-d, %Y"),
            reason.text()
        ),
    })
}

/// Render-ready content for a pane (H6 maps it onto the wire).
#[derive(Debug, Clone, PartialEq)]
pub struct HueyDocument {
    pub title: String,
    pub banner: Option<Banner>,
    pub markdown: String,
    pub blocks: Vec<MdBlock>,
    /// The report shown, if any.
    pub date: Option<NaiveDate>,
    pub version: Option<u32>,
    /// Buttons below the body. Inline `nostromo-action:` links in `markdown`
    /// are actions too.
    pub actions: Vec<DocAction>,
}

impl HueyDocument {
    pub fn from_markdown(title: String, banner: Option<Banner>, markdown: String) -> Self {
        let blocks = crate::markdown_blocks::markdown_to_blocks(&markdown);
        Self {
            title,
            banner,
            markdown,
            blocks,
            date: None,
            version: None,
            actions: Vec::new(),
        }
    }

    /// What a `Document` pane carries on the wire.
    pub fn into_wire(self) -> PaneContentWire {
        PaneContentWire::Document {
            title: self.title,
            banner: self.banner.map(|b| DocBanner {
                level: match b.level {
                    BannerLevel::Info => DocBannerLevel::Info,
                    BannerLevel::Warning => DocBannerLevel::Warning,
                },
                text: b.text,
            }),
            blocks: self.blocks,
            actions: self.actions,
        }
    }
}

/// The ids of the actions a document carries (`ClientMsg::PaneAction`).
pub mod action {
    pub const SETUP_START: &str = "setup.start";
    pub const SETUP_RESCAN: &str = "setup.rescan";
    pub const SETUP_OPEN_INTERESTS: &str = "setup.open_interests";
    pub const SETUP_IMPORT_INTERESTS: &str = "setup.import_interests";
    pub const SETUP_CONFIRM: &str = "setup.confirm";
    pub const SETUP_CONFIRM_RUN_NOW: &str = "setup.confirm_run_now";
    pub const REPORT_PREV: &str = "report.prev";
    pub const REPORT_NEXT: &str = "report.next";
    pub const REPORT_TODAY: &str = "report.today";
    pub const REPORT_REGENERATE: &str = "report.regenerate";
    /// `report.version:<n>`
    pub const REPORT_VERSION_PREFIX: &str = "report.version:";
    /// `verdict:<date>:<version>:<pick>:<useful|interesting|meh|hype|wrong_project>`
    pub const VERDICT_PREFIX: &str = "verdict:";
}

/// Shown before setup (H6 replaces it with the full setup document).
pub fn not_set_up_document() -> HueyDocument {
    HueyDocument::from_markdown(
        "Huey".to_string(),
        None,
        "Huey is not set up on this machine. It has read nothing.\n".to_string(),
    )
}

/// Shown when there is no report at all yet.
pub fn no_report_document(today: NaiveDate, reason: MissingReason) -> HueyDocument {
    HueyDocument::from_markdown(
        title(today, 1),
        Some(Banner {
            level: reason.banner_level(),
            text: format!("There is no report yet: {}.", reason.text()),
        }),
        "No report yet.\n".to_string(),
    )
}

// ── Document builders (H6) ───────────────────────────────────────────────────

/// A button.
pub fn button(id: &str, label: &str, primary: bool) -> DocAction {
    DocAction {
        id: id.to_string(),
        label: label.to_string(),
        primary,
    }
}

/// `Version 2, generated 2026-10-26 06:41.` The time is the daemon's local
/// time, as the caller formats it.
pub fn version_line(version: u32, generated: &str) -> String {
    format!("Version {version}, generated {}.", esc(generated))
}

/// The verdict kinds in the order the links appear, with their labels.
pub const VERDICT_CHOICES: [(VerdictKind, &str, &str); 5] = [
    (VerdictKind::Useful, "useful", "Useful"),
    (VerdictKind::Interesting, "interesting", "Interesting"),
    (VerdictKind::Meh, "meh", "Meh"),
    (VerdictKind::Hype, "hype", "Hype"),
    (VerdictKind::WrongProject, "wrong_project", "Wrong project"),
];

/// The id's last part for a verdict kind (`wrong_project`).
pub fn verdict_slug(kind: VerdictKind) -> &'static str {
    VERDICT_CHOICES
        .iter()
        .find(|(k, _, _)| *k == kind)
        .map(|(_, slug, _)| *slug)
        .unwrap_or("meh")
}

/// The verdict kind a slug names.
pub fn verdict_from_slug(slug: &str) -> Option<VerdictKind> {
    VERDICT_CHOICES
        .iter()
        .find(|(_, s, _)| *s == slug)
        .map(|(k, _, _)| *k)
}

/// One paragraph of verdict links for pick `pick` (from 1) of a version. The
/// chosen verdict, if any, is in bold. These `nostromo-action:` links are
/// the only ones a document carries.
pub fn verdict_paragraph(
    date: NaiveDate,
    version: u32,
    pick: usize,
    chosen: Option<VerdictKind>,
) -> String {
    let links: Vec<String> = VERDICT_CHOICES
        .iter()
        .map(|(kind, slug, label)| {
            let link = format!(
                "[{label}](<nostromo-action:{}{date}:{version}:{pick}:{slug}>)",
                action::VERDICT_PREFIX
            );
            if chosen == Some(*kind) {
                format!("**{link}**")
            } else {
                link
            }
        })
        .collect();
    format!("Verdict: {}", links.join(" · "))
}

fn bullets_of(items: impl IntoIterator<Item = String>) -> String {
    items
        .into_iter()
        .map(|i| format!("- {i}\n"))
        .collect::<String>()
}

fn source_lines(sources: &[ContextSource]) -> String {
    bullets_of(sources.iter().map(|s| {
        let note = s
            .note
            .as_deref()
            .map(|n| format!(" ({})", esc(n)))
            .unwrap_or_default();
        format!("**{}**: {}{}", esc(&s.name), esc(&s.path), note)
    }))
}

/// Before the first scan (D6): says it has read nothing, lists what it would
/// read (from config, no reads) and offers one button.
pub fn setup_prescan_document(sources: &[ContextSource]) -> HueyDocument {
    let md = format!(
        "Huey is not set up on this machine. It has read nothing.\n\n\
         When you press the button, Huey reads the places below, in memory only: \
         nothing is saved, fetched or sent until you confirm.\n\n\
         ### What it would read\n\n{}",
        source_lines(sources)
    );
    let mut doc = HueyDocument::from_markdown("Huey".to_string(), None, md);
    doc.actions = vec![button(
        action::SETUP_START,
        "Set up Huey on this machine",
        true,
    )];
    doc
}

/// After the scan: sources, projects with their "how it runs" lines, the
/// interests file's status, and what to do next.
pub fn setup_scan_document(scan: &SetupScan, interests_path: &Path) -> HueyDocument {
    let projects = if scan.projects.is_empty() {
        "No projects in flight were found.\n".to_string()
    } else {
        bullets_of(scan.projects.iter().map(|p| {
            let description = p
                .description
                .as_deref()
                .map(|d| format!(" ({})", esc(d)))
                .unwrap_or_default();
            format!("**{}**{description}: {}", esc(&p.name), esc(&p.how_it_runs))
        }))
    };
    let (interests, importable) = match &scan.interests {
        InterestsStatus::Existing => (
            format!(
                "Your interests file is at {}. Edit it any time; changes apply from the next report.\n",
                esc(&interests_path.display().to_string())
            ),
            false,
        ),
        InterestsStatus::Missing => (
            "There is no interests file yet. Open the interests file to write a draft from the projects above, edit it, then confirm.\n".to_string(),
            false,
        ),
        InterestsStatus::ImportableFrom(from) => (
            format!(
                "There is no interests file yet, but an older one sits at {}. Import it, or open a fresh draft, then confirm.\n",
                esc(&from.display().to_string())
            ),
            true,
        ),
    };
    let md = format!(
        "Huey has read this machine ({}), in memory only. Nothing is saved until you confirm.\n\n\
         ### Sources read\n\n{}\n### Projects in flight\n\n{projects}\n### Interests\n\n{interests}",
        esc(&scan.machine),
        source_lines(&scan.context_sources),
    );
    let mut doc = HueyDocument::from_markdown("Huey: set up".to_string(), None, md);
    doc.actions.push(button(
        action::SETUP_OPEN_INTERESTS,
        "Open interests file",
        false,
    ));
    if importable {
        doc.actions.push(button(
            action::SETUP_IMPORT_INTERESTS,
            "Import older interests file",
            false,
        ));
    }
    doc.actions
        .push(button(action::SETUP_RESCAN, "Scan again", false));
    doc.actions
        .push(button(action::SETUP_CONFIRM, "Confirm setup", true));
    doc.actions.push(button(
        action::SETUP_CONFIRM_RUN_NOW,
        "Confirm and run now",
        false,
    ));
    doc
}

/// A date (or version) with no report behind it.
pub fn missing_report_document(
    date: NaiveDate,
    version: Option<u32>,
    actions: Vec<DocAction>,
) -> HueyDocument {
    let what = match version {
        Some(v) => format!(
            "There is no version {v} of the report for {}.",
            date.format("%A, %b %-d, %Y")
        ),
        None => format!("There is no report for {}.", date.format("%A, %b %-d, %Y")),
    };
    let mut doc = HueyDocument::from_markdown(
        title(date, 1),
        Some(Banner {
            level: BannerLevel::Info,
            text: what.clone(),
        }),
        format!("{what}\n"),
    );
    doc.actions = actions;
    doc
}

/// The digest behind a report, as blocks. Digest lines hold titles from the
/// user's own files and from the news, so every line is escaped: only the
/// digest's own headings and bullets keep their markup, and nothing in it can
/// become a link, an image or an action.
pub fn context_document(date: NaiveDate, version: u32, digest: &str) -> HueyDocument {
    let mut md = String::new();
    for line in digest.lines() {
        let trimmed = line.trim_start();
        let hashes = trimmed.chars().take_while(|c| *c == '#').count();
        if (1..=6).contains(&hashes) && trimmed[hashes..].starts_with(' ') {
            md.push_str(&format!(
                "{} {}",
                &trimmed[..hashes],
                esc(trimmed[hashes..].trim())
            ));
        } else if let Some(rest) = trimmed.strip_prefix("- ") {
            let indent = &line[..line.len() - trimmed.len()];
            md.push_str(&format!("{indent}- {}", esc(rest)));
        } else {
            md.push_str(&esc(line));
        }
        md.push('\n');
    }
    let mut doc = HueyDocument::from_markdown(
        format!("Huey context, {}", date.format("%a %b %-d, %Y")),
        None,
        md,
    );
    doc.date = Some(date);
    doc.version = Some(version);
    doc
}

/// No digest to show for `date`.
pub fn no_digest_document(date: NaiveDate) -> HueyDocument {
    HueyDocument::from_markdown(
        format!("Huey context, {}", date.format("%a %b %-d, %Y")),
        None,
        "No digest: there is no report for this date.\n".to_string(),
    )
}

/// The Context pane before setup.
pub fn context_not_set_up_document() -> HueyDocument {
    HueyDocument::from_markdown(
        "Huey context".to_string(),
        None,
        "Huey has read nothing on this machine yet, so there is no context to show.\n".to_string(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, 26).unwrap()
    }

    fn footer() -> Footer {
        Footer {
            looked_at: 57,
            sources_read: 8,
            read_in_full: vec!["Claude Code changelog".into()],
            quiet: vec!["Latent Space".into()],
            failed: vec![],
            in_flight: vec!["nostromo".into(), "mother".into()],
            dropped: vec![],
            ain_skip_reason: None,
            posture_unavailable: false,
        }
    }

    #[test]
    fn untrusted_text_cannot_become_a_link_or_html() {
        let text = esc("[x](javascript:alert(1)) <img src=x> # h");
        let blocks = crate::markdown_blocks::markdown_to_blocks(&text);
        let json = serde_json::to_string(&blocks).unwrap();
        assert!(!json.contains("\"link\""), "{json}");
        assert!(!json.contains("heading"), "{json}");
    }

    #[test]
    fn a_long_drop_list_still_fits_the_footer() {
        let mut f = footer();
        f.dropped = (0..9)
            .map(|n| FooterDrop {
                item_id: format!("s:{n}"),
                title: "word ".repeat(30),
                reason: "benchmark news".into(),
            })
            .collect();
        f.ain_skip_reason = Some("only minor fixes this week".into());
        let text = footer_text(&f);
        assert!(words(&text) <= FOOTER_MAX_WORDS, "{text}");
        assert!(text.contains("Dropped:"), "{text}");
        assert!(text.contains("No Also-in-the-news line: only minor fixes this week."));
    }

    #[test]
    fn a_banner_names_the_date_and_the_reason() {
        let b = banner_for(
            day() - chrono::Duration::days(1),
            day(),
            MissingReason::ModelFailed,
        )
        .unwrap();
        assert!(b.text.contains("Sunday, Oct 25, 2026"), "{}", b.text);
        assert!(b.text.contains("model run failed"));
        assert!(banner_for(day(), day(), MissingReason::Asleep).is_none());
    }
}
