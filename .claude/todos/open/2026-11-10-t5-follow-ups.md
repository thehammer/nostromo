# T5 follow-ups

- [ ] `/compact` unanswered write: in the stdout-before-summary and missing-stdout cases the stray unanswered `/compact` write is tallied as an agent turn with a NoText problem (agent_turns 2, agent_problems 1; should be 0 and 0). A pending compact's unanswered write should not tally. Left alone in PR #459 as not small and safe.
- [ ] Process death mid-compact (the CLI dying between the `/compact` write and its record) is untested: check `pending_compact` is dropped and the Compact button comes back.

## From Perri's review of PR #465 (My open PRs 2/3)

- `ModelChipAppearanceTests.testAFocusedChipDrawsAFocusRingOnEverySideThatAnUnfocusedOneLacks` fails locally on main for Perri (environment-dependent; passes in CI).
- A visible window of an inactive app counts as `visible` for the PR-list demand level. This matches the plan text, not its prose ("someone is looking").
- The demand reporter's 60 s re-evaluation timer and the 1 s debounce timer run while the Overview is hidden (local only, no daemon traffic unless the level changes).
