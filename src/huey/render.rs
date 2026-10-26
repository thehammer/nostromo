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

use chrono::NaiveDate;
use serde::{Deserialize, Serialize};

use crate::huey::budget::Mode;
use crate::ipc::protocol::{MdBlock, MdSpan};

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

/// `report.md`.
pub fn render_markdown(report: &Report) -> String {
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
        }
    }
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
        let b = banner_for(day() - chrono::Duration::days(1), day(), MissingReason::ModelFailed)
            .unwrap();
        assert!(b.text.contains("Sunday, Oct 25, 2026"), "{}", b.text);
        assert!(b.text.contains("model run failed"));
        assert!(banner_for(day(), day(), MissingReason::Asleep).is_none());
    }
}
