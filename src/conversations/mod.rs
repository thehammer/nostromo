//! A private, Mac-only history of the conversations Nostromo focuses started.
//!
//! Distinct from `mother::origin::SessionHistory` (an authority record for
//! Mother job origins, ids only). This one holds what the Resume tab lists:
//! title, label, agent, project, branch, model, PR numbers, one first-prompt
//! line (never for a sensitive conversation or one the sensitive-text guard
//! flags) and what is needed to find and resume the conversation.
//!
//! Nothing here is logged (ids and fixed words only), sent to a network or
//! non-operator peer, or reachable by an MCP tool.

pub mod backfill;
pub mod first_prompt;
pub mod list;
pub mod store;
pub mod transcript;

pub use first_prompt::{FirstPrompt, Reason};
pub use store::{ConversationEntry, ConversationHistory};

/// Milliseconds since the Unix epoch.
pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// The longest title a user may give a conversation (the same as a focus label).
pub const MAX_TITLE_CHARS: usize = 60;

/// A user's title as stored: one line, with control, bidi, zero-width and
/// line-separator characters dropped, whitespace runs collapsed, cut at
/// [`MAX_TITLE_CHARS`] and trimmed again; `None` when nothing is left (which
/// clears the title).
pub fn normalized_title(raw: Option<&str>) -> Option<String> {
    let line = crate::data::work::untrusted::one_line(raw?, usize::MAX);
    let capped: String = line.chars().take(MAX_TITLE_CHARS).collect();
    let capped = capped.trim();
    (!capped.is_empty()).then(|| capped.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_title_loses_every_invisible_class_and_stays_on_one_line() {
        let classes: [(&str, &str); 8] = [
            ("control", "A\u{1}B\u{7f}C"),
            (
                "bidi override",
                "A\u{202A}B\u{202B}C\u{202C}\u{202D}\u{202E}",
            ),
            ("bidi isolate", "A\u{2066}B\u{2067}C\u{2068}\u{2069}"),
            ("direction mark", "A\u{200E}B\u{200F}C"),
            ("zero width", "A\u{200B}B\u{200C}C\u{200D}\u{FEFF}"),
            ("line separator", "A\u{2028}B\u{2029}C"),
            ("newline", "A\nB\r\nC"),
            ("tab", "A\tB\tC"),
        ];
        for (name, raw) in classes {
            let got = normalized_title(Some(raw)).unwrap();
            let visible: String = got.chars().filter(|c| !c.is_whitespace()).collect();
            assert_eq!(visible, "ABC", "{name}: {got:?}");
            assert!(
                got.chars()
                    .all(|c| !c.is_control() && !crate::data::work::untrusted::is_invisible(c)),
                "{name}: {got:?}"
            );
            assert!(!got.contains('\n'), "{name}");
        }
        assert_eq!(normalized_title(Some("\u{200B}\u{202E}\n")), None);
    }

    #[test]
    fn a_title_is_cut_after_cleaning_not_before() {
        let raw = format!("\u{200B}{}", "x".repeat(80));
        assert_eq!(normalized_title(Some(&raw)).unwrap().chars().count(), 60);
    }
}
