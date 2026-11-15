# T5 follow-ups

- [ ] `/compact` unanswered write: in the stdout-before-summary and missing-stdout cases the stray unanswered `/compact` write is tallied as an agent turn with a NoText problem (agent_turns 2, agent_problems 1; should be 0 and 0). A pending compact's unanswered write should not tally. Left alone in PR #459 as not small and safe.
- [ ] Process death mid-compact (the CLI dying between the `/compact` write and its record) is untested: check `pending_compact` is dropped and the Compact button comes back.
- [ ] Perri side pane (PR #466): `javaScriptCanOpenWindowsAutomatically = true` is deliberate so every popup reaches the navigation policy. Consequence: a script-opened window to an allowed host becomes a new tab without a click (needed for sign-in popups). Hammer to confirm.
- [ ] Perri side pane (PR #466): `about:srcdoc`, `data:` and `blob:` iframes are blocked (subframes must be https). This may break parts of Jira or GitHub; check in the signed-in run.
- [ ] `ScreenshotRedactionTests` order-pollution: a stray `repoorg-*.out` temp file makes the tests depend on run order. Find who leaves it and clean up.
