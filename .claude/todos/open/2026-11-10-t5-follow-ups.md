# T5 follow-ups

- [ ] `/compact` unanswered write: in the stdout-before-summary and missing-stdout cases the stray unanswered `/compact` write is tallied as an agent turn with a NoText problem (agent_turns 2, agent_problems 1; should be 0 and 0). A pending compact's unanswered write should not tally. Left alone in PR #459 as not small and safe.
- [ ] Process death mid-compact (the CLI dying between the `/compact` write and its record) is untested: check `pending_compact` is dropped and the Compact button comes back.

## From Perri's review of PR #465 (My open PRs 2/3)

- `ModelChipAppearanceTests.testAFocusedChipDrawsAFocusRingOnEverySideThatAnUnfocusedOneLacks` fails locally on main for Perri (environment-dependent; passes in CI).
- A visible window of an inactive app counts as `visible` for the PR-list demand level. This matches the plan text, not its prose ("someone is looking").
- The demand reporter's 60 s re-evaluation timer and the 1 s debounce timer run while the Overview is hidden (local only, no daemon traffic unless the level changes).

- [ ] Session history 2: the VoiceOver and keyboard flow of the resume choice sheets (worktree gone, open elsewhere, Return = Cancel, Esc) is verified only by unit tests, not with VoiceOver or a real key press. Check it by hand.
- [ ] Session history 2: resuming a conversation from another folder relies on the spike's outcome A (Claude's `--resume` finds the transcript from a different directory); nothing in the tests exercises the real CLI. Re-check after a Claude CLI upgrade.

## From Perri side pane (PR #466)

- [ ] Perri side pane (PR #466): `javaScriptCanOpenWindowsAutomatically = true` is deliberate so every popup reaches the navigation policy. Consequence: a script-opened window to an allowed host becomes a new tab without a click (needed for sign-in popups). Hammer to confirm.
- [ ] Perri side pane (PR #466): `about:srcdoc`, `data:` and `blob:` iframes are blocked (subframes must be https). This may break parts of Jira or GitHub; check in the signed-in run.
- [ ] `ScreenshotRedactionTests` order-pollution: a stray `repoorg-*.out` temp file makes the tests depend on run order. Find who leaves it and clean up.
- [ ] Perri side pane (PR #466): two local-only flakes, each seen once in three full-class runs of `ReviewWebViewIntegrationTests`: `testARealClickOnATargetBlankLinkToAnAllowedHostOpensAPaneTab` and `testAPRChangeKeepsTheTabWithTypedTextAndMarksIt`. Not reproduced since; watch CI.
- [ ] Perri side pane (PR #466): the Rust test `huey_run.rs::the_overall_deadline_fails_the_run_and_frees_the_lock` (`AlreadyRunning`) flaked once on CI. Unrelated to the pane; look at the lock release timing.
- [ ] Perri side pane (PR #466): a real server 3xx redirect to an IdP during the first load could not be tested (the `nostromo-fixture:` scheme cannot answer with a redirect), so the IdP case is simulated by loading the IdP URL as a main-frame navigation. Check a real redirect in the signed-in run.

## From Perri's review of PR #469 (My open PRs 3/3)

- The hidden-polling budget (at most 20 requests/hour while the Overview is hidden) was not measured by the reviewer: measure it with a real token.
- VoiceOver on the preview, picker and sheet, and a real notify-and-switch (a focus created by Start a session, the window coming forward, the keyboard landing in the input), are Hammer's to verify.
- `MainMenuKeyEquivalentsUnchangedTests` lives in `ReviewPaneAccessibilityTests.swift` (PR #466), not in a file of its own; find it there when touching main-menu key equivalents.
