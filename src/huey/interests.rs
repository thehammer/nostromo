//! The interests file (`<state root>/huey/interests.md`): the only store of
//! the user's preferences (AC27).
//!
//! Parsed by heading text, case-insensitive, by prefix:
//! "What I care about", "Want more of", "Want less of", "Ignore entirely" and
//! "How it runs". Anything else is kept in the file and never fatal: a missing
//! section is a warning, not an error. Bullets in the first four sections get
//! ids `i1`, `i2`, … in file order. Backticked terms in "Ignore entirely"
//! bullets are hard filters. A "How it runs" bullet (`- **mother**: …`)
//! replaces Huey's own line for that project.

use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum InterestSection {
    Care,
    WantMore,
    WantLess,
    Ignore,
}

impl InterestSection {
    /// The short label the digest shows: `(care)`, `(want more)`, …
    pub fn label(self) -> &'static str {
        match self {
            InterestSection::Care => "care",
            InterestSection::WantMore => "want more",
            InterestSection::WantLess => "want less",
            InterestSection::Ignore => "ignore",
        }
    }

    /// The heading as the draft writes it.
    pub fn heading(self) -> &'static str {
        match self {
            InterestSection::Care => "What I care about, and why",
            InterestSection::WantMore => "Want more of",
            InterestSection::WantLess => "Want less of",
            InterestSection::Ignore => "Ignore entirely",
        }
    }

    pub const ALL: [InterestSection; 4] = [
        InterestSection::Care,
        InterestSection::WantMore,
        InterestSection::WantLess,
        InterestSection::Ignore,
    ];
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InterestBullet {
    /// `i1`, `i2`, … in file order.
    pub id: String,
    pub section: InterestSection,
    /// The bullet text without the `- ` marker, continuation lines joined.
    pub text: String,
    /// The bold lead (`**Agent harnesses …**`), when the bullet starts with one.
    pub lead: Option<String>,
    /// Backticked terms; only "Ignore entirely" bullets carry any.
    pub hard_terms: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Interests {
    pub bullets: Vec<InterestBullet>,
    /// Lower-cased project id → the user's own "how it runs" line.
    pub how_it_runs: BTreeMap<String, String>,
    /// Section-level problems (a missing section). Never names bullet text.
    pub warnings: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Heading {
    Section(InterestSection),
    HowItRuns,
    Other,
}

fn classify_heading(text: &str) -> Heading {
    let t = text.trim().to_lowercase();
    if t.starts_with("what i care about") {
        Heading::Section(InterestSection::Care)
    } else if t.starts_with("want more") {
        Heading::Section(InterestSection::WantMore)
    } else if t.starts_with("want less") {
        Heading::Section(InterestSection::WantLess)
    } else if t.starts_with("ignore") {
        Heading::Section(InterestSection::Ignore)
    } else if t.starts_with("how it runs") {
        Heading::HowItRuns
    } else {
        Heading::Other
    }
}

/// Parse the interests file. Never fails.
pub fn parse(text: &str) -> Interests {
    let mut current: Option<Heading> = None;
    let mut seen = [false; 4];
    // (heading, bullet text) in file order; continuation lines are joined.
    let mut raw: Vec<(Heading, String)> = Vec::new();
    let mut in_comment = false;
    for line in text.lines() {
        let trimmed = line.trim();
        if in_comment {
            if trimmed.contains("-->") {
                in_comment = false;
            }
            continue;
        }
        if trimmed.starts_with("<!--") {
            in_comment = !trimmed.contains("-->");
            continue;
        }
        if let Some(h) = line.strip_prefix("## ") {
            let heading = classify_heading(h);
            if let Heading::Section(s) = heading {
                seen[s as usize] = true;
            }
            current = Some(heading);
            continue;
        }
        if line.starts_with('#') {
            current = None;
            continue;
        }
        let Some(heading) = current else { continue };
        if let Some(rest) = line.strip_prefix("- ").or_else(|| line.strip_prefix("* ")) {
            raw.push((heading, rest.trim().to_string()));
        } else if !trimmed.is_empty() && line.starts_with([' ', '\t']) {
            if let Some((h, last)) = raw.last_mut() {
                if *h == heading {
                    last.push(' ');
                    last.push_str(trimmed);
                }
            }
        }
    }

    let mut out = Interests::default();
    for (heading, text) in raw {
        if text.is_empty() {
            continue;
        }
        match heading {
            Heading::Section(section) => {
                let hard_terms = if section == InterestSection::Ignore {
                    backticked(&text)
                } else {
                    Vec::new()
                };
                out.bullets.push(InterestBullet {
                    id: format!("i{}", out.bullets.len() + 1),
                    section,
                    lead: bold_lead(&text),
                    text,
                    hard_terms,
                });
            }
            Heading::HowItRuns => {
                if let Some((project, line)) = how_it_runs_entry(&text) {
                    out.how_it_runs.insert(project, line);
                }
            }
            Heading::Other => {}
        }
    }
    for section in InterestSection::ALL {
        if !seen[section as usize] {
            out.warnings
                .push(format!("missing section: {}", section.heading()));
        }
    }
    out
}

impl Interests {
    /// Every backticked term in "Ignore entirely", in file order, deduplicated
    /// case-insensitively.
    pub fn hard_terms(&self) -> Vec<&str> {
        let mut seen = std::collections::BTreeSet::new();
        self.bullets
            .iter()
            .flat_map(|b| b.hard_terms.iter())
            .filter(|t| seen.insert(t.to_lowercase()))
            .map(String::as_str)
            .collect()
    }

    /// Is `project` named under "Ignore entirely"? A case-insensitive whole
    /// word match of the project name anywhere in an Ignore bullet.
    pub fn ignores_project(&self, project: &str) -> bool {
        self.bullets
            .iter()
            .filter(|b| b.section == InterestSection::Ignore)
            .any(|b| contains_word(&b.text, project))
    }

    /// Does `line` contain any hard-ignore term (case-insensitive, whole word)?
    pub fn hard_term_in(&self, line: &str) -> Option<&str> {
        self.hard_terms()
            .into_iter()
            .find(|term| contains_word(line, term))
    }

    /// The user's correction for `project`, if any.
    pub fn how_it_runs_for(&self, project: &str) -> Option<&str> {
        self.how_it_runs
            .get(&project.to_lowercase())
            .map(String::as_str)
    }
}

/// Case-insensitive match of `needle` in `haystack` where neither side of the
/// match continues a word (letters, digits, `_`).
pub(crate) fn contains_word(haystack: &str, needle: &str) -> bool {
    let needle = needle.trim();
    if needle.is_empty() {
        return false;
    }
    let hay = haystack.to_lowercase();
    let needle = needle.to_lowercase();
    let is_word = |c: char| c.is_alphanumeric() || c == '_';
    let mut from = 0;
    while let Some(pos) = hay[from..].find(&needle) {
        let start = from + pos;
        let end = start + needle.len();
        let before_ok = hay[..start].chars().next_back().is_none_or(|c| !is_word(c))
            || !needle.chars().next().is_some_and(is_word);
        let after_ok = hay[end..].chars().next().is_none_or(|c| !is_word(c))
            || !needle.chars().next_back().is_some_and(is_word);
        if before_ok && after_ok {
            return true;
        }
        from = start + hay[start..].chars().next().map_or(1, char::len_utf8);
    }
    false
}

fn backticked(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut parts = text.split('`');
    parts.next();
    while let (Some(term), Some(_)) = (parts.next(), parts.next()) {
        let term = term.trim();
        if !term.is_empty() && !out.iter().any(|t: &String| t.eq_ignore_ascii_case(term)) {
            out.push(term.to_string());
        }
    }
    // An odd number of backticks leaves the last term unterminated: skip it.
    out
}

fn bold_lead(text: &str) -> Option<String> {
    let rest = text.strip_prefix("**")?;
    let end = rest.find("**")?;
    let lead = rest[..end].trim();
    (!lead.is_empty()).then(|| lead.to_string())
}

/// `**mother**: text`, `mother: text` → (`mother`, `text`).
fn how_it_runs_entry(text: &str) -> Option<(String, String)> {
    let (project, line) = match bold_lead(text) {
        Some(lead) => {
            let after = text.strip_prefix("**")?;
            let after = &after[after.find("**")? + 2..];
            (lead, after.trim_start_matches([':', ' ', '-', '—']).trim())
        }
        None => {
            let (p, l) = text.split_once(':')?;
            (p.trim().to_string(), l.trim())
        }
    };
    let project = project.trim().trim_matches('`').to_lowercase();
    if project.is_empty() || line.is_empty() {
        return None;
    }
    Some((project, line.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn word_match_respects_boundaries() {
        assert!(contains_word("PHP and Laravel", "php"));
        assert!(!contains_word("graphpha", "php"));
        assert!(contains_word("uses claude -p daily", "claude -p"));
        assert!(!contains_word("Google", "go"));
        assert!(contains_word("x (Go) y", "go"));
    }

    #[test]
    fn unterminated_backtick_is_not_a_term() {
        assert_eq!(backticked("a `PHP` and `Lara"), vec!["PHP".to_string()]);
    }
}
