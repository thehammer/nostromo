# T5 follow-ups

- [ ] `/compact` unanswered write: in the stdout-before-summary and missing-stdout cases the stray unanswered `/compact` write is tallied as an agent turn with a NoText problem (agent_turns 2, agent_problems 1; should be 0 and 0). A pending compact's unanswered write should not tally. Left alone in PR #459 as not small and safe.
- [ ] Process death mid-compact (the CLI dying between the `/compact` write and its record) is untested: check `pending_compact` is dropped and the Compact button comes back.
- [ ] Session history 2: the VoiceOver and keyboard flow of the resume choice sheets (worktree gone, open elsewhere, Return = Cancel, Esc) is verified only by unit tests, not with VoiceOver or a real key press. Check it by hand.
- [ ] Session history 2: resuming a conversation from another folder relies on the spike's outcome A (Claude's `--resume` finds the transcript from a different directory); nothing in the tests exercises the real CLI. Re-check after a Claude CLI upgrade.
