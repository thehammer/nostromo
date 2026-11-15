# T5 follow-ups

- [ ] `/compact` unanswered write: in the stdout-before-summary and missing-stdout cases the stray unanswered `/compact` write is tallied as an agent turn with a NoText problem (agent_turns 2, agent_problems 1; should be 0 and 0). A pending compact's unanswered write should not tally. Left alone in PR #459 as not small and safe.
- [ ] Process death mid-compact (the CLI dying between the `/compact` write and its record) is untested: check `pending_compact` is dropped and the Compact button comes back.

## From Perri's review of PR #465 (My open PRs 2/3)

- `ModelChipAppearanceTests.testAFocusedChipDrawsAFocusRingOnEverySideThatAnUnfocusedOneLacks` fails locally on main for Perri (environment-dependent; passes in CI).
- A visible window of an inactive app counts as `visible` for the PR-list demand level. This matches the plan text, not its prose ("someone is looking").
- The demand reporter's 60 s re-evaluation timer and the 1 s debounce timer run while the Overview is hidden (local only, no daemon traffic unless the level changes).

## From Perri side pane (PR #466)

- [ ] Perri side pane (PR #466): `javaScriptCanOpenWindowsAutomatically = true` is deliberate so every popup reaches the navigation policy. Consequence: a script-opened window to an allowed host becomes a new tab without a click (needed for sign-in popups). Hammer to confirm.
- [ ] Perri side pane (PR #466): `about:srcdoc`, `data:` and `blob:` iframes are blocked (subframes must be https). This may break parts of Jira or GitHub; check in the signed-in run.
- [ ] `ScreenshotRedactionTests` order-pollution: a stray `repoorg-*.out` temp file makes the tests depend on run order. Find who leaves it and clean up.
- [ ] Perri side pane (PR #466): two local-only flakes, each seen once in three full-class runs of `ReviewWebViewIntegrationTests`: `testARealClickOnATargetBlankLinkToAnAllowedHostOpensAPaneTab` and `testAPRChangeKeepsTheTabWithTypedTextAndMarksIt`. Not reproduced since; watch CI.
- [ ] Perri side pane (PR #466): the Rust test `huey_run.rs::the_overall_deadline_fails_the_run_and_frees_the_lock` (`AlreadyRunning`) flaked once on CI. Unrelated to the pane; look at the lock release timing.
- [ ] Perri side pane (PR #466): a real server 3xx redirect to an IdP during the first load could not be tested (the `nostromo-fixture:` scheme cannot answer with a redirect), so the IdP case is simulated by loading the IdP URL as a main-frame navigation. Check a real redirect in the signed-in run.
