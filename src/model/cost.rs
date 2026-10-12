//! Static cost ordering of model families and effort levels.
//!
//! The CLI's model catalogue carries no prices (contract F7), so the relative
//! cost of a family is the one thing Nostromo hard-codes. Per-MTok pricing at
//! the time of writing (F9): Haiku 5.5 $0.10/$0.50 < Sonnet 5.5 $2/$10 <
//! Opus 5.5 $4/$20 < Fable 5.1 $10/$50.

/// Rank of every family Nostromo knows the price of, cheapest first.
const KNOWN_FAMILIES: [(&str, u32); 4] = [("haiku", 1), ("sonnet", 2), ("opus", 3), ("fable", 4)];

/// Rank given to a family Nostromo has no price for: above every known one, so
/// an unknown family is treated as the most expensive (it needs approval and
/// warns rather than slipping through as "cheap").
pub const UNKNOWN_FAMILY_RANK: u32 = 100;

/// Cost rank of a family alias (`"opus"`), or of a full model name that names
/// a known family (`"claude-sonnet-4-6"`). Unknown → [`UNKNOWN_FAMILY_RANK`].
pub fn family_rank(model: &str) -> u32 {
    known_family_of(model)
        .and_then(|family| KNOWN_FAMILIES.iter().find(|(f, _)| *f == family))
        .map(|(_, rank)| *rank)
        .unwrap_or(UNKNOWN_FAMILY_RANK)
}

/// The known family a model alias or full name belongs to, if any.
pub fn known_family_of(model: &str) -> Option<&'static str> {
    let lower = model.to_ascii_lowercase();
    KNOWN_FAMILIES
        .iter()
        .map(|(f, _)| *f)
        .find(|f| lower == *f || lower.split(['-', '_', '.']).any(|part| part == *f))
}

/// Effort levels, cheapest first.
pub const EFFORT_LEVELS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

/// The effort a model runs at when none is chosen.
pub const DEFAULT_EFFORT: &str = "medium";

/// Rank of an effort level: low 1 < medium 2 < high 3 < xhigh 4 < max 5.
/// `None` (the model's default) ranks as `medium`. An unknown level ranks
/// above every known one, for the same reason an unknown family does.
pub fn effort_rank(effort: Option<&str>) -> u32 {
    let level = effort.unwrap_or(DEFAULT_EFFORT);
    EFFORT_LEVELS
        .iter()
        .position(|l| *l == level)
        .map(|i| i as u32 + 1)
        .unwrap_or(EFFORT_LEVELS.len() as u32 + 1)
}

/// Context window, in tokens, of a resolved model name: 1M by default
/// (Haiku/Sonnet/Opus 5.5, Fable 5.1), 200K for `claude-haiku-4-5*` (F9).
pub fn context_window(resolved: &str) -> u64 {
    if resolved.starts_with("claude-haiku-4-5") {
        200_000
    } else {
        1_000_000
    }
}
