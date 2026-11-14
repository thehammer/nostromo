//! The one line of a conversation's first prompt that a history row may show.
//!
//! Pure. Text that is sensitive, flagged by the repo's guard, an image, or a
//! slash command is dropped *here*: it never reaches the store, a log or a frame.

use crate::data::work::untrusted::one_line;
use crate::sensitive_text::{first_class, GuardConfig};
use serde::{Deserialize, Serialize};

/// Longest first prompt shown, in characters (the ellipsis counts).
pub const MAX_CHARS: usize = 80;
/// Longest first line the guard is asked to scan; longer is treated as flagged.
pub const MAX_SCAN_BYTES: usize = 4096;
/// What the Mac sends for an image-only message (`ChatSession.imageOnlyText`).
pub const IMAGE_ONLY_TEXT: &str = "(image attached)";

/// Why no first-prompt text is stored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reason {
    SensitiveConversation,
    LookedSensitive,
    Off,
    Image,
    /// A slash command; carries `/name` only, never its arguments.
    Command(String),
}

impl Reason {
    /// The fixed word sent on the wire and stored.
    pub fn word(&self) -> String {
        match self {
            Reason::SensitiveConversation => "sensitive_conversation".into(),
            Reason::LookedSensitive => "looked_sensitive".into(),
            Reason::Off => "off".into(),
            Reason::Image => "image".into(),
            Reason::Command(name) => format!("command:{name}"),
        }
    }

    fn from_word(word: &str) -> Self {
        match word {
            "sensitive_conversation" => Reason::SensitiveConversation,
            "off" => Reason::Off,
            "image" => Reason::Image,
            other => match other.strip_prefix("command:") {
                Some(name) => Reason::Command(name.to_owned()),
                // Anything unknown is the safest withheld reason.
                None => Reason::LookedSensitive,
            },
        }
    }
}

impl Serialize for Reason {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.word())
    }
}

impl<'de> Deserialize<'de> for Reason {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Reason::from_word(&String::deserialize(d)?))
    }
}

/// A conversation's first prompt, as stored.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "snake_case")]
pub enum FirstPrompt {
    /// Not seen yet.
    #[default]
    None,
    Text(String),
    Withheld(Reason),
}

/// The slash command name (`/name`) `text` starts with, if any: a `/`, then a
/// name with no `/` or whitespace (`/compact`, `/model haiku`; not `/usr/bin`).
pub fn slash_command(text: &str) -> Option<String> {
    let t = text.trim();
    let rest = t.strip_prefix('/')?;
    let name: String = rest.chars().take_while(|c| !c.is_whitespace()).collect();
    if name.is_empty() || name.contains('/') {
        None
    } else {
        Some(format!("/{name}"))
    }
}

/// The first prompt for a message that opens a conversation.
pub fn derive(text: &str, has_images: bool, sensitive: bool, enabled: bool) -> FirstPrompt {
    if sensitive {
        return FirstPrompt::Withheld(Reason::SensitiveConversation);
    }
    if !enabled {
        return FirstPrompt::Withheld(Reason::Off);
    }
    if has_images || text.trim() == IMAGE_ONLY_TEXT {
        return FirstPrompt::Withheld(Reason::Image);
    }
    if let Some(name) = slash_command(text) {
        return FirstPrompt::Withheld(Reason::Command(name));
    }
    let Some(line) = text.lines().find(|l| !l.trim().is_empty()) else {
        return FirstPrompt::None;
    };
    if line.len() > MAX_SCAN_BYTES
        || first_class(line, &GuardConfig::default()).is_some()
    {
        return FirstPrompt::Withheld(Reason::LookedSensitive);
    }
    let shown = one_line(line, MAX_CHARS);
    if shown.is_empty() {
        FirstPrompt::None
    } else {
        FirstPrompt::Text(shown)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(p: &FirstPrompt) -> &str {
        match p {
            FirstPrompt::Text(t) => t,
            other => panic!("not text: {other:?}"),
        }
    }

    #[test]
    fn takes_the_first_line_collapsed_and_cut_with_an_ellipsis() {
        let long = format!("Fix   the\tpicker {}\nsecond line", "x".repeat(200));
        let p = derive(&long, false, false, true);
        let t = text(&p);
        assert!(t.starts_with("Fix the picker x"), "{t}");
        assert_eq!(t.chars().count(), MAX_CHARS);
        assert!(t.ends_with('…'));
        assert!(!t.contains("second"));
    }

    #[test]
    fn skips_blank_lines_and_drops_invisible_characters() {
        let p = derive("\n  \n\u{200B}Hel\u{202E}lo\u{0007} there", false, false, true);
        assert_eq!(text(&p), "Hello there");
    }

    #[test]
    fn an_image_or_the_placeholder_is_withheld_as_image() {
        assert_eq!(
            derive("look", true, false, true),
            FirstPrompt::Withheld(Reason::Image)
        );
        assert_eq!(
            derive(IMAGE_ONLY_TEXT, false, false, true),
            FirstPrompt::Withheld(Reason::Image)
        );
    }

    #[test]
    fn a_slash_command_keeps_its_name_and_no_arguments() {
        assert_eq!(
            derive("/compact keep the SECRETWORD plan", false, false, true),
            FirstPrompt::Withheld(Reason::Command("/compact".into()))
        );
        // A path is not a command.
        assert!(matches!(
            derive("/usr/bin/env is odd", false, false, true),
            FirstPrompt::Text(_)
        ));
    }

    #[test]
    fn sensitive_and_off_withhold_everything() {
        assert_eq!(
            derive("hello", false, true, true),
            FirstPrompt::Withheld(Reason::SensitiveConversation)
        );
        assert_eq!(
            derive("hello", false, false, false),
            FirstPrompt::Withheld(Reason::Off)
        );
    }

    #[test]
    fn a_guard_flagged_line_is_withheld() {
        let ssn = derive("Call back, SSN was 219-09-9999 ok", false, false, true);
        assert_eq!(ssn, FirstPrompt::Withheld(Reason::LookedSensitive));
        let huge = "a".repeat(MAX_SCAN_BYTES + 1);
        assert_eq!(
            derive(&huge, false, false, true),
            FirstPrompt::Withheld(Reason::LookedSensitive)
        );
    }

    #[test]
    fn reasons_round_trip_through_their_fixed_words() {
        for r in [
            Reason::SensitiveConversation,
            Reason::LookedSensitive,
            Reason::Off,
            Reason::Image,
            Reason::Command("/compact".into()),
        ] {
            let json = serde_json::to_string(&FirstPrompt::Withheld(r.clone())).unwrap();
            let back: FirstPrompt = serde_json::from_str(&json).unwrap();
            assert_eq!(back, FirstPrompt::Withheld(r));
        }
    }
}
