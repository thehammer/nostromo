//! Port of the bash truncation helper from lib/fred/format.sh.
//!
//! Truncates a string to at most `max_width` display columns, appending `…`
//! when the string is shortened.  Assumes ASCII + common Latin-1 (1 char = 1
//! column); for full Unicode width handling a crate like `unicode-width` would
//! be needed (out of scope for phase 1).

/// Truncate `s` to at most `max_width` characters.  Returns `s` unchanged if
/// it fits.  Appends `…` when trimmed.
pub fn truncate(s: &str, max_width: usize) -> String {
    if max_width == 0 {
        return String::new();
    }
    if s.chars().count() <= max_width {
        return s.to_string();
    }
    let truncated: String = s.chars().take(max_width.saturating_sub(1)).collect();
    format!("{truncated}…")
}

/// Pad `s` to exactly `width` characters (truncate or right-pad with spaces).
pub fn pad_or_truncate(s: &str, width: usize) -> String {
    let t = truncate(s, width);
    format!("{t:<width$}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_string_unchanged() {
        assert_eq!(truncate("hello", 10), "hello");
    }

    #[test]
    fn exact_length_unchanged() {
        assert_eq!(truncate("hello", 5), "hello");
    }

    #[test]
    fn long_string_truncated() {
        let t = truncate("hello world", 8);
        assert!(t.chars().count() <= 8); // 7 chars + ellipsis
        assert!(t.ends_with('…'));
    }

    #[test]
    fn zero_width_returns_empty() {
        assert_eq!(truncate("hello", 0), "");
    }
}
