//! The MCP `initialize` `instructions` Nostromo sends to the agents it spawns.
//!
//! Claude Code puts a connected MCP server's `instructions` into the session's
//! system prompt even while that server's tools are deferred, which makes this
//! the one place an agent that has never searched for a tool can learn that
//! one exists. The text is computed per connection and only for sessions the
//! daemon spawned (see `server::handle_initialize`).
//!
//! Today it carries the tracker paragraph only; the rest of the
//! inject-nostromo-context backlog item extends [`nostromo_instructions`].

/// Hard ceiling on the text, dynamic line included.
pub const MAX_INSTRUCTIONS_CHARS: usize = 1_200;

const TRACKER_PARAGRAPH: &str = "You are in Nostromo. To keep a live status board beside the transcript \
for this session, use the tracker tool; load it with ToolSearch `select:mcp__nostromo__nostromo_tracker`. \
Offer a tracker when three or more threads are live, at the start of a triage or morning check-in; \
open one without asking when the user asks you to keep track. \
Refer to things by id (Sentry issue, ticket key, PR, job id, facility or org id); never put resident or \
patient names, dates of birth, medical record numbers, diagnoses, contact details or raw database rows \
on a tracker. Staged commands are display-only; the human runs them. \
Update items one at a time, read deltas with op:\"read\", and never re-send the board.";

/// The instructions for a Nostromo-spawned session. `open_topic` is the topic
/// of the board bound to the caller's focus, when there is one.
pub fn nostromo_instructions(open_topic: Option<&str>) -> String {
    let mut text = TRACKER_PARAGRAPH.to_string();
    if let Some(topic) = open_topic {
        // The topic is validated (`^[a-z0-9][a-z0-9-]{0,47}$`) when a board is
        // opened; a board adopted from a path derives it from the file name, so
        // keep the line bounded and single-line regardless.
        let topic: String = topic.chars().filter(|c| !c.is_control() && *c != '"').take(64).collect();
        text.push_str(&format!(
            "\nA tracker is open in this focus: \"{topic}\". Call op:\"read\" to load it."
        ));
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_text_names_the_tool_and_the_rules() {
        let t = nostromo_instructions(None);
        for needle in [
            "mcp__nostromo__nostromo_tracker",
            "keep track",
            "never put resident or patient names",
            "display-only",
            "op:\"read\"",
        ] {
            assert!(t.contains(needle), "missing {needle:?}");
        }
        assert!(!t.contains("A tracker is open"));
    }

    #[test]
    fn the_dynamic_line_names_the_topic_and_the_budget_holds() {
        let t = nostromo_instructions(Some("sentry-triage"));
        assert!(t.ends_with(
            "A tracker is open in this focus: \"sentry-triage\". Call op:\"read\" to load it."
        ));
        assert!(t.chars().count() <= MAX_INSTRUCTIONS_CHARS);
        assert!(nostromo_instructions(None).chars().count() <= MAX_INSTRUCTIONS_CHARS);
        let long = nostromo_instructions(Some(&"x".repeat(500)));
        assert!(long.chars().count() <= MAX_INSTRUCTIONS_CHARS);
    }
}
