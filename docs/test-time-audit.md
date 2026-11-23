# Test time and value audit

Read-only analysis. **Nothing was deleted, skipped, `#[ignore]`d, weakened or edited:** no test, workflow, Makefile or source file is changed by the PR that adds this document. Every number below has a source in "Methods" (§7). Where a number could not be measured, §6 says so.

Measured 2026-11-23 on `main` (head `bfb58f02`, run 45257797577) plus nine earlier `main` pushes; times are wall-clock seconds unless marked.

## 1. Summary

**The critical path of a PR is the Mac shards, not the Rust job.** Over ten green `main` runs the slowest `Mac tests shard` job took 1,217-1,490 s (median about 1,350 s, about 22 min); `Rust tests` took 898-925 s in nine of ten (one run, 45187785606, took 1,566 s); `Python tooling tests` 241-400 s; `Swift tests (NostromoKit)` 188-256 s; `iOS simulator build` 90-289 s. Any Rust or Python speed-up shortens CI minutes and Mother's `python-test` gate, but shortens a PR's wall-clock time only once the Mac shards are shorter than it. The Rust job is the second-longest job (about 15 min).

What the time is made of:

- **Rust (`Rust tests` job, 4 vCPU `ubuntu-latest`):** about 250 s build (`Finished test profile ... in 4m 11s`) plus about 635 s executing 178 test binaries one after another (sum of libtest `finished in` = 630 s; the lib binary 69 s, `tracker_concurrency` 79 s). In the RWX sandbox (4 vCPU, same shape) **`cargo nextest` ran all 9,527 tests in 345 s**, against about 635 s for the same tests under libtest in CI, so about 290 s (46% of execution, about 33% of the job) is available from nextest alone. Nextest was installed from the prebuilt release in seconds, no `cargo install` needed.
- **Mac (3 shards, `macos-26`):** about 2,910 s of summed test time (10,446 tests, 624 classes) plus about 300-370 s per shard of build and launch. The shards are **not balanced**: per-class sums put shard 1 at 946 s, shard 2 at 891 s and shard 3 (the catch-all, which every new class lands in) at 1,072 s, and shard 3 was the slowest job in 6 of 10 runs. A greedy rebalance by the measured per-class times gives 970 s each: about 100 s off the slowest shard on paper. Ten classes hold 37% of the summed test time (1,079 of 2,910 s), thirty classes hold 57%.
- **Python (`python-test`):** in CI the 20 suites sum to 309 s (`Ran N tests in` lines) and `scripts/qa/tests` alone is 196 s of that. The "~20 min" figure in #502 is the same suites on a loaded 10-core Mac, not CI.

No test in the top ~40 is a retire candidate on evidence. Almost all are regression or contract pins added with a bug or review finding, or mutation proofs; the realistic savings are mechanical (nextest, rebalancing, removing real-time waits, a CI-size seed count behind an env var), not pruning.

| Job | Current (median of 10 runs) | Biggest levers | Estimated saving | Risk |
|---|---|---|---|---|
| `Mac tests shard N/3` (critical path) | about 1,350 s (slowest shard) | `mac_shards.py regenerate` from fresh logs; remove two real 15 s waits; sample the nested-loop layout tests | about 100 s (rebalance, within runner noise of about 150 s) plus about 10 s (waits) | Low (rebalance is the documented procedure); the sampling is per-test review |
| `Rust tests` | about 905 s | `cargo nextest` (parallel across binaries); a CI seed count; injectable timeouts | about 290 s (nextest, sandbox-measured) plus 10-60 s (seeds, timeouts) | Medium: tests run one process each; doc tests need their own step |
| `Python tooling tests` | about 330 s | run the slow suites in parallel (`scripts/python-test-parallel.sh` exists); `scripts/qa/tests` per-file split | about 100 s (estimate: 309 s of suites bounded by `scripts/qa/tests` at 196 s) | Medium: `python-test` recipe is guarded; CI runner core count not measured |
| `Rust clippy` | about 130 s | none worth taking | | |
| `Swift tests (NostromoKit)` / iOS | about 215 s / about 130 s | none worth taking (they share one macOS slot) | | |
| Tiering (PR gate vs merge/nightly) | n/a | full-range seeds and slow QA suites off the PR path | 10-60 s of Rust CPU per PR, plus the schedule's coverage | Gap stated in §4.5 |

## 2. Timing inventory

### 2.1 Per job and step, ten `main` push runs

Source: `gh run view <id> --repo thehammer/nostromo --json jobs`, job `completedAt - startedAt` and per-step times. Runs (newest first): 45257797577, 45216673899, 45187785606, 45186615862, 45129168783, 45108879854, 45086640246, 45067919486, 45067911288, 45059831878. All ten succeeded.

| Job | Min | Median | Max | Dominant step |
|---|---|---|---|---|
| `Rust tests` | 898 | about 912 | 1,566 (45187785606), 1,124 (45067911288) | `Test` step 875-906 s typical (1,548 s in the outlier); toolchain install 7-10 s |
| `Rust clippy` | 123 | 137 | 154 | `Clippy` 100-138 s |
| `Rust format` | 17 | 23 | 40 | n/a |
| `Python tooling tests` (macos-latest) | 241 | 331 | 400 | `Python tooling tests` step 227-375 s; shellcheck install 6-12 s |
| `Swift tests (NostromoKit)` | 188 | 218 | 256 | `make kit-test` 170-235 s |
| `iOS simulator build` | 90 | 133 | 289 (45257797577) | `Build for iOS Simulator` 76-267 s |
| `Mac tests shard 1/3` | 1,200 | 1,308 | 1,490 | `make mac-test (shard)` 1,071-1,337 s plus `Build Mac app (compile gate)` 69-125 s |
| `Mac tests shard 2/3` | 985 | 1,183 | 1,225 | `make mac-test (shard)` 971-1,202 s |
| `Mac tests shard 3/3` | 993 | 1,252 | 1,490 | `make mac-test (shard)` 978-1,464 s |
| `Swift tests (Mac app)` aggregate | 7 | 12 | 16 | n/a (no macOS slot) |

The Rust outlier (1,566 s) is a single run; its cause was not investigated (§6).

### 2.2 Mac shards: wall time per run and imbalance

Job wall seconds (shard 1 includes its compile gate), and which shard was slowest:

| Run | Shard 1 | Shard 2 | Shard 3 | Slowest |
|---|---|---|---|---|
| 45257797577 | 1,448 | 985 | 1,490 | 3 |
| 45216673899 | 1,348 | 1,225 | 1,421 | 3 |
| 45187785606 | 1,308 | 1,222 | 1,384 | 3 |
| 45186615862 | 1,217 | 1,162 | 1,052 | 1 |
| 45129168783 | 1,490 | 1,133 | 993 | 1 |
| 45108879854 | 1,307 | 1,218 | 1,134 | 1 |
| 45086640246 | 1,208 | 1,195 | 1,265 | 3 |
| 45067919486 | 1,383 | 1,176 | 1,134 | 1 |
| 45067911288 | 1,234 | 1,121 | 1,318 | 3 |
| 45059831878 | 1,200 | 1,209 | 1,239 | 3 |

Shard 3 was slowest in 6 of 10 runs, shard 1 in 4, shard 2 never. Run-to-run noise on one shard is large (shard 3: 993-1,490 s, a 50% spread) because the runners are hosted and shared, which limits what any rebalance can show in a single run.

Test-seconds per shard (sum of `Test Case ... passed (N seconds)`; `shard-N.json` reports `seconds`), three runs with full logs (`mac-test-log-shard-N` artifacts):

| Run | Shard 1 (tests, s) | Shard 2 | Shard 3 | Executed (1/2/3) |
|---|---|---|---|---|
| 45257797577 | 992 | 817 | 1,091 | 2,596 / 3,245 / 4,605 |
| 45216673899 | 940 | 913 | 1,072 | same |
| 45187785606 | 907 | 945 | 1,053 | 2,594 / 3,237 / 4,595 |

So shard 3 carries 44% of the tests (4,605 of 10,446) and the most test time in all three. `mac-shards.json` says `balanced_from: 42353503588`; `docs/ci.md` records that assignment as 508 s each with 7,850 tests. The suite is now 10,446 tests and the assignment has drifted. The step time minus test seconds (for example shard 3, 45257797577: step 1,464 s, tests 1,091 s) is about 300-370 s of build, launch and result handling per shard.

### 2.3 Rust: per-binary (libtest) and per-test (nextest)

Per binary: `Rust tests` job 137984090432 (run 45257797577), `test result: ... finished in Xs` for 178 binaries (9,528 tests); sum 630 s; executing window 635 s (first `Running` 20:21:48 to last result). 107 of 178 binaries finish in under 1 s. Top 30:

| Seconds | Tests | Binary |
|---|---|---|
| 78.85 | 11 | `tests/tracker_concurrency.rs` |
| 69.25 | 4,309 | `unittests src/lib.rs` |
| 36.51 | 154 | `tests/tracker_engine.rs` |
| 33.52 | 108 | `tests/terminal_text_redaction.rs` |
| 29.74 | 85 | `tests/terminal_text_delivery.rs` |
| 29.06 | 37 | `tests/mcp_terminal_guards.rs` |
| 28.77 | 196 | `tests/ipc_peer_gating.rs` |
| 27.87 | 42 | `tests/fred_rate_limit.rs` |
| 18.62 | 83 | `tests/terminal_follow_tools.rs` |
| 16.91 | 87 | `tests/approvals_wire.rs` |
| 16.73 | 34 | `tests/terminal_follow.rs` |
| 11.36 | 43 | `tests/claude_login.rs` |
| 10.15 | 40 | `tests/google_fred_sources.rs` |
| 9.43 | 79 | `tests/tracker_two_way.rs` |
| 9.22 | 22 | `tests/terminal_text_memory.rs` |
| 8.41 | 165 | `tests/approvals_guard.rs` |
| 8.14 | 9 | `tests/approvals_preview.rs` |
| 8.00 | 7 | `tests/tracker_invisible_chars.rs` |
| 7.88 | 35 | `tests/tracker_two_way_followup.rs` |
| 7.43 | 33 | `tests/terminal_core.rs` |
| 7.15 | 25 | `tests/authored_prs_budget.rs` |
| 5.82 | 50 | `tests/tracker_injection.rs` |
| 5.61 | 86 | `tests/work_repo_docs.rs` |
| 5.59 | 105 | `tests/model_switch.rs` |
| 5.55 | 21 | `tests/approvals_unreadable.rs` |
| 5.48 | 56 | `tests/ecs_connect.rs` |
| 5.34 | 8 | `tests/perri_action_write_through.rs` |
| 5.03 | 17 | `tests/daemon_restart_guard.rs` |
| 4.64 | 51 | `tests/authored_prs_merge.rs` |
| 4.60 | 3 | `tests/no_shell_behaviour.rs` |

The top 10 binaries are 369 s of the 630 s, the top 20 are 466 s. #517 reported a sum of 732-843 s and `tracker_concurrency` at 108-139 s; this run is faster (630 s, 79 s), so the binary times vary a lot between runs on the hosted runner.

Per test: `cargo nextest run --no-fail-fast` in the RWX sandbox (4 vCPU, 15 GB, Linux, `CARGO_PROFILE_DEV_DEBUG=0` to keep the disk from filling, as `docs/rwx-sandbox.md` §4 requires), nextest 0.9.152, installed from the prebuilt release (`curl -LsSf https://get.nexte.st/latest/linux | tar zxf - -C ~/.cargo/bin`). Result: `9527 tests run: 9527 passed, 11 skipped` in **345.154 s** of test execution (the exec took 8 min 8 s including a 2 min 20 s build). Per-test times below are with up to 4 tests running at once, so they include CPU contention and are an upper bound on a test's standalone time. The sum of all per-test times is 1,380 s, and 1,380 / 4 cores = 345 s, so nextest kept the four cores saturated.

Top 30 tests (seconds; binary `nostromo` is the lib):

| Seconds | Binary | Test |
|---|---|---|
| 47.60 | `tracker_concurrency` | `four_hundred_interleavings_lose_no_edit` |
| 29.71 | `tracker_engine` | `a_thousand_maximal_writes_keep_the_serialised_change_log_bounded` |
| 20.03 | lib | `data::perri_pr_native::tests::a_stalled_diff_fetch_publishes_an_error_snapshot_via_run_and_generated_at_advances_on_recovery` |
| 20.02 | lib | `data::perri_pr_native::tests::a_stalled_diff_fetch_fails_within_the_configured_timeout_instead_of_hanging_the_source` |
| 15.01 | lib | `ipc::session_manager::queue_tests::a_stuck_write_makes_only_its_own_id_already_delivered_others_stay_not_found` |
| 12.80 | lib | `terminal::staging::tests::s3::nothing_of_a_local_terminals_output_reaches_its_staging_only_follower_by_any_call_or_end` |
| 12.38 | lib | `terminal::staging::tests::s3::nothing_of_a_remote_terminals_output_reaches_its_staging_only_follower_by_any_call_or_end` |
| 10.02 | lib | `data::perri_pr_native::tests::a_slow_but_within_timeout_diff_fetch_still_succeeds_with_the_full_diff` |
| 8.11 | `terminal_text_delivery` | `a_curl_command_continued_by_an_open_quote_is_delivered_redacted_around_lines_with_hidden_runs` |
| 7.29 | `fred_rate_limit` | `calendar_backs_off_2_then_4_seconds_after_consecutive_429s_without_retry_after` |
| 7.15 | `fred_rate_limit` | `mailbox_backs_off_2_then_4_seconds_after_consecutive_429s_without_retry_after` |
| 6.95 | `terminal_text_delivery` | `a_curl_command_continued_by_an_open_quote_is_delivered_redacted_around_rows_of_emoji` |
| 6.74 | `google_fred_sources` | `consecutive_throttles_back_off_exponentially` |
| 6.73 | lib | `ipc::session_manager::queue_tests::every_typed_message_is_delivered_taken_back_removed_or_dropped_exactly_once` |
| 6.67 | `terminal_text_redaction` | `a_curl_command_continued_by_an_open_quote_is_redacted_before_and_after_a_megabyte_of_lines_with_hidden_runs` |
| 6.44 | lib | `ipc::session_manager::queue_tests::merged_batches_are_delivered_taken_back_removed_or_dropped_exactly_once` |
| 6.25 | lib | `ipc::session_manager::queue_tests::the_merged_race_test_catches_a_decision_made_without_waiting_for_the_in_flight_write` |
| 6.13 | `terminal_core` | `after_the_cap_is_revoked_not_one_more_terminal_byte_is_written_to_the_connection` |
| 6.08 | `terminal_follow` | `stopping_while_the_agent_is_mid_turn_discards_queued_and_buffered_deliveries_but_not_the_users_own_message` |
| 6.01 | `fred_rate_limit` | `calendar_throttle_wait_is_never_shorter_than_the_normal_poll_interval` |
| 6.01 | `fred_rate_limit` | `mailbox_throttle_wait_is_never_shorter_than_the_normal_poll_interval` |
| 5.89 | lib | `ipc::session_manager::queue_tests::the_race_test_catches_a_decision_made_without_waiting_for_the_in_flight_write` |
| 5.83 | `terminal_follow` | `while_the_agent_is_mid_turn_deliveries_wait_and_arrive_combined_in_one_message` |
| 5.77 | `ipc_peer_gating` | `background_tasks::a_tcp_peer_gets_a_wake_turns_origin_and_merge_but_never_the_notification_text_and_a_sensitive_tag_gets_neither` |
| 5.72 | `terminal_text_redaction` | `a_continued_curl_across_two_calls_is_redacted_next_to_a_megabyte_of_lines_with_hidden_characters` |
| 5.68 | `tracker_concurrency` | `a_flooded_board_keeps_the_dropped_marker_seed_7a126120` |
| 5.54 | `fred_rate_limit` | `mailbox_retry_after_wins_over_the_exponential_step` |
| 5.42 | `terminal_text_memory` | `random_control_soup_never_exceeds_the_caps` |
| 5.23 | `approvals_preview` | `a_hung_file_system_never_stalls_the_next_request` |
| 5.23 | `fred_rate_limit` | `calendar_retry_after_wins_over_the_exponential_step` |
| 5.22 / 5.21 | `perri_action_write_through` | `a_daemon_created_focus_recreated_under_a_reused_tag_inherits_no_pin` / `a_focus_recreated_under_a_reused_tag_inherits_no_pin` |

Distribution: 39 tests take over 5 s and make up 351 s of the 1,380 s; 7,892 tests take under 0.1 s and make up 98 s. The suite is a long tail of fast tests plus a small head. Doc tests (1 test, `src/mdns.rs`, about 4 s in CI) are not run by nextest.

### 2.4 Mac: slowest classes and tests

Source: `Test Case '-[NostromoTests.<Class> <test>]' passed (N seconds)` lines in the `mac-test-log-shard-1..3` artifacts of runs 45257797577, 45216673899, 45187785606; each number is the mean over the three runs (every test ran in all three; 10,446 cases per run across the shards). Shard column is the current assignment from `shard-N.json` (3 = catch-all).

Top 30 classes by mean summed time:

| Class | Mean s | Cases | Shard |
|---|---|---|---|
| `ReviewWebViewIntegrationTests` | 364.0 | 64 | 3 |
| `MotherDetailScrollTests` | 167.3 | 23 | 3 |
| `FocusActivityRowSidebarTests` | 129.1 | 8 | 3 |
| `TrackerStructureEditingTests` | 71.5 | 79 | 3 |
| `GitHubSignedOut404HintTests` | 67.4 | 12 | 3 |
| `ReviewPaneAccessibilityTests` | 66.3 | 26 | 3 |
| `StagingDrawerViewTests` | 56.6 | 136 | 3 |
| `MotherDetailVerticalOverflowTests` | 52.5 | 6 | 3 |
| `ReviewPaneRedactionTests` | 52.0 | 15 | 2 |
| `PerriFocusContainerLayoutTests` | 51.9 | 12 | 2 |
| `ApprovalCardTests` | 46.5 | 146 | 3 |
| `TeriSurfaceViewTests` | 46.2 | 55 | 1 |
| `StagingHazardsTests` | 38.3 | 55 | 2 |
| `WindowContentOverflowTests` | 37.6 | 7 | 2 |
| `PlanDisplayLimitsTests` | 37.4 | 17 | 3 |
| `PaneBlankDetectorTests` | 35.3 | 79 | 2 |
| `AuthoredPrMergeAppearanceTests` | 32.6 | 22 | 3 |
| `TrackerFixupTests` | 29.9 | 46 | 3 |
| `MotherOverviewAndCrewOverflowTests` | 28.9 | 6 | 1 |
| `ApprovalQuestionLayoutTests` | 26.5 | 14 | 3 |
| `ApprovalQuestionCardTests` | 25.2 | 85 | 3 |
| `TrackerPaneViewTests` | 25.0 | 46 | 3 |
| `ApprovalCardRenderTests` | 23.9 | 12 | 2 |
| `FocusSplitOversizedChildTests` | 23.3 | 4 | 2 |
| `PerriRowControlsRenderTests` | 23.2 | 9 | 3 |
| `TrackerEditingTests` | 22.9 | 41 | 3 |
| `AlwaysAllowCardTests` | 22.8 | 23 | 2 |
| `ToolsOfflineAppStoreTests` | 21.6 | 5 | 2 |
| `SessionRuleCardTests` | 20.6 | 15 | 2 |
| `MotherDetailSwitchTests` | 20.3 | 31 | 3 |

(Cases is the count in the first log.) Top 30 tests by mean time:

| Mean s | Test |
|---|---|
| 64.5 | `FocusActivityRowSidebarTests.testTheSlotNeverTouchesAnythingElseInARealRow` |
| 50.4 | `FocusActivityRowSidebarTests.testFlippingTheMarkNeverMovesAnythingInTheRealRows` |
| 30.4 | `MotherDetailScrollTests.testTheEndOfTheOverviewInViewStaysPutWhileTheSectionsAboveItGrowAndShrink` |
| 29.4 | `StagingHazardsTests.testTheDifferentialCorpusAgreesWithTheDaemonsVerdictOnEveryField` |
| 23.8 | `MotherDetailScrollTests.testTheOverviewTracksItsClipThroughTwoHundredScrollerStyleFlipsWithoutALayoutStorm` |
| 18.9 | `WindowContentOverflowTests.testMainLayoutFollowsTheWindowThroughResizeSequences` |
| 18.4 | `MotherDetailVerticalOverflowTests.testEachFieldLongOnItsOwnFitsTheWindow` |
| 17.1 | `MotherDetailVerticalOverflowTests.testContentThatGrowsAfterTheFirstLayoutKeepsFittingStageByStage` |
| 15.8 | `SessionRuleCardTests.testThePickRevertsAfterFifteenSeconds` |
| 15.8 | `AlwaysAllowCardTests.testThePanelRevertsAfterTheSessionPicksLifetime` |
| 15.3 | `MotherDetailScrollTests.testTheRowsInViewStayPutWhileTheSectionsAboveThePlanGrowAndShrink` |
| 13.4 | `MotherDetailScrollTests.testLiveUpdatesLeaveFocusAndTheDraftAloneAndWriteNothing` |
| 12.7 | `MarkdownCardLayoutTests.testTheCardsTextViewIsNeverShorterThanItsLaidOutFencedCodeAcrossWidthsAndHalfPointOffsets` |
| 11.4 | `ToolsOfflineAppStoreTests.testThePaceBarsBadgeShowsOnlyForTheActiveFocusSessionAndOnlyOnceItsToolsAreOffline` |
| 11.2 | `PlanDisplayLimitsTests.testPlansUnderTheLimitsAreNotTruncated` |
| 11.1 | `MotherDetailScrollTests.testWhenTheDocumentShrinksThePositionClampsToTheNewEnd` |
| 10.6 | `TeriSurfaceViewTests.testASurfaceShorterThanTheStripPlusTheMinimumListHeightKeepsItsStripAndLetsTheMinimumYield` |
| 10.6 | `GitHubSignedOut404HintTests.testA404OnAnotherHostGetsNoHint` |
| 10.2 | `ToolsOfflineAppStoreTests.testALostBridgeShowsOnceTheGracePeriodPassesAndEveryWayOfEndingTheSessionOrReconnectingClearsIt` |
| 10.1 | `MotherOverviewAndCrewOverflowTests.testATallCrewPanelStillFitsWhileHundredsOfLongJobsAreListed` |
| 10.0 | `MotherDetailScrollTests.testTheOverviewNeverScrollsSidewaysWithEitherScrollerStyleWhenTheLogChanges` |
| 9.5 | `PlanDisplayLimitsTests.testScrollingATruncatedPlanBuildsOnlyTheRowsNearTheViewport` |
| 9.1 | `StagingDrawerViewTests.testTheDrawerIsNeverMoreThan45PercentOfThePaneBody` |
| 8.8 | `ReviewWebViewIntegrationTests.testTheUnsentProbeReturnsPromptlyAndReportsUnsentWhileThePageIsBusy` |
| 8.7 | `FocusSplitOversizedChildTests.testAnOversizedInactiveTabOfTheMotherPaneCannotChangeTheWindowEitherBeforeOrAfterItIsSelected` |
| 8.6 | `TeriSurfaceViewTests.testInASmallWindowAboveAChatTheSurfaceKeepsItsStripAndNothingConflicts` |
| 8.6 | `TeriSurfaceViewTests.testTheConflictProbeSeesAnUnsatisfiableRequiredConstraint` |
| 8.4 | `WindowContentOverflowTests.testMainLayoutFitsItsWindowForEveryFocusShapeAndWindowSize` |
| 8.3 | `StagingDrawerViewTests.testTheDisplayedCommandIsTheStagedCommandForEveryGoldenCommand` |
| 8.0 | `CompactButtonTests.testClickingCompactDoesNotClearTheTranscript` |

The distribution is flatter than Rust's: 377 of 624 classes take under 1 s in total; the top 100 classes are 2,436 s of 2,910 s (84%).

### 2.5 Python: per-suite times in CI

Source: `Python tooling tests` job 137984090659 (run 45257797577), the `Ran N tests in Xs` line after each of the 20 `python3 -m unittest discover -s <dir> -v` commands; total 309 s.

| Suite | Tests | Seconds |
|---|---|---|
| `scripts/qa/tests` | 315 | 196.5 |
| `tests/fake_mother` | 48 | 41.5 |
| `tests/qa_instance` | 315 | 18.6 |
| `tests/fake_claude_perm` | 98 | 15.4 |
| `tests/operator_pin` | 55 | 12.4 |
| `tests/mother_policy` | 63 | 6.9 |
| `tests/ci_remote` | 58 | 4.6 |
| the other 13 | | under 3 s each (about 12 s together) |

Compare #502's loaded-Mac figures: `scripts/qa/tests` ~900 s, `tests/operator_pin` 367 s. On the CI runner `operator_pin` is 12 s: the per-test `codesign` cost in #502 was load, not the suite. **The logs do not give per-test times:** `unittest -v` prints no durations. An approximation is the gap between successive `... ok` timestamps (first test in a suite includes its `setUpModule`); the large gaps are `scripts/qa/tests` `test_teri_fred_smoke` (about 66 s of attributed time, mostly a module-level setup that launches about 15 QA scripts), `test_background_wake` (46 s), `test_mother_crew` (38 s; its end-to-end test about 30 s), `test_mother_hold` (27 s). Treat these as approximate.

## 3. Per-item assessment (the top 40)

How each row was assessed, and how deep: **what it protects** comes from the test's name, its file header, and the first commit that added the file; **PROTECTED** means that commit's message mentions a bug, regression, review, Perri, mutation or pin (a keyword match on the message, not a check of each test: when the label says "not checked per test", a human should confirm before any change); **covered elsewhere** says "none identified" unless I can name the other test; this is not a coverage analysis (no mutation or coverage run was done). **Category:** (a) race/fuzz with counts, (b) real processes, (c) golden/contract/wire fixtures, (d) UI layout/pixel (Mac), (e) other. "Saving" is wall-clock for the job unless noted; for tests inside a binary, the saving applies in CI today only if the test is on the binary's critical path.

### 3.1 Rust

| # | Item (time) | Cat. | Protects | Covered elsewhere? | PROTECTED? | Sleeps / waits | Recommendation | Saving |
|---|---|---|---|---|---|---|---|---|
| 1 | `tracker_concurrency` binary (79 s libtest; `four_hundred_interleavings_lose_no_edit` 47.6 s nextest) | a | Zero lost edits: a seeded 400-interleaving oracle over four writers (PRD 42 T3a). Counts are env-configurable (`TRACKER_FUZZ_COUNT`, `TRACKER_FUZZ_START`, `TRACKER_FUZZ_SEED`), default `INTERLEAVINGS = 400` | none identified (the oracle shares nothing with the daemon's rule by design) | **PROTECTED**: #476, #490 (lost-edit fix), #491 (fuzz counterexamples), #503 (Perri leftovers); named-seed pins such as `a_flooded_board_keeps_the_dropped_marker_seed_7a126120` are counterexamples | none | **TIER**: keep the pinned-seed tests per PR; run 100-400 on PR (see §4.3), full range on a schedule | libtest: about 55 s on this binary at 100 seeds (estimate: 47.6 s test x 3/4); nextest: about 9 s (CPU-bound) |
| 2 | `tracker_engine::a_thousand_maximal_writes_keep_the_serialised_change_log_bounded` (29.7 s) | e | The change log stays bounded after 1,000 maximal writes (`MAX_ENTRIES = 1_000`) | none identified | file from #253 (T0a); this test's own commit not checked | none (CPU) | **KEEP** (or SPEED-UP if the 1,000 writes build the board with per-write full serialisation: not investigated) | n/a |
| 3 | `perri_pr_native::...a_stalled_diff_fetch_publishes_an_error_snapshot_via_run...` (20.0 s) | e | A stalled diff fetch yields an error snapshot and recovers | the next row exercises the same timeout | **PROTECTED**: introduced with #160 (bound every GitHub request; message mentions the hang) | Real wall clock: wiremock delays the response by `GITHUB_HTTP_TIMEOUT_SECS + 30` (const 20 s) and the test waits out the 20 s timeout. Its doc comment says `tokio::time::pause()` was tried and races real socket I/O | **SPEED-UP**: make the timeout injectable for tests (an override like the existing `API_BASE_OVERRIDE`), shrinking each of the three tests to about 1 s | up to about 20 s wall in the lib binary (the three run in parallel; the saving is the tail beyond the other lib tests, not 50 s) |
| 4 | `perri_pr_native::...a_stalled_diff_fetch_fails_within_the_configured_timeout...` (20.0 s) | e | The headline pin for #160 | row 3 shares setup | **PROTECTED** (#160) | as row 3 | **SPEED-UP** as row 3 | included in row 3 |
| 5 | `perri_pr_native::...a_slow_but_within_timeout_diff_fetch_still_succeeds...` (10.0 s) | e | The positive side of the timeout | row 3 | **PROTECTED** (#160) | real 10 s delay | **SPEED-UP** as row 3 | included |
| 6 | `queue_tests::a_stuck_write_makes_only_its_own_id_already_delivered...` (15.0 s) | e | After the write wait limit, only the in-flight id answers `already_delivered` | the race tests below | file from #514 (message queue S3; the keyword scan did not hit; the test's own PR not checked) | waits out the real `WRITE_WAIT_LIMIT` ("the limit is five seconds" in the test comment); three queue verbs each wait | **SPEED-UP**: inject the limit (a `#[cfg(test)]` constant or the existing `SKIP_WRITE_WAIT` cell in `queue.rs`) | up to about 10-15 s CPU; wall in the lib binary only if it is the tail |
| 7 | `queue_tests::every_typed_message_...exactly_once` + `merged_batches_...` + the two `..._race_test_catches_a_decision_made_without_waiting...` (6.7 + 6.4 + 6.3 + 5.9 s = 25 s) | a | Seeds `1..=RACE_SEEDS` (`const RACE_SEEDS: u64 = 1000`, not env-configurable today) over real threads; the two `catches` tests are mutation proofs that the race test fails when the in-flight wait is removed | the `catches` tests are the proof for the first two; do not retire either side | **PROTECTED**: mutation proofs by design; Perri used a larger count (the task says 5,000+) | `thread::sleep` of 1-100 ms per step inside the plans (lines 88-743) | **TIER**: make `RACE_SEEDS` read an env var (default 1000; PR value can stay 1000: it is 25 s of CPU, 6 s of 4-core wall); schedule 5,000+ | none on PR; adds the nightly depth Perri used |
| 8 | `terminal::staging::tests::s3::nothing_of_a_{local,remote}_terminals_output_reaches...` (12.8 + 12.4 s) | e | A staging-only follower never receives terminal output | none identified | file from #445 (S3a staging-only follow); keyword scan not conclusive | `wait_long` polls every 20 ms up to `LONG_WAIT = 90 s`, and `PAST_COOLDOWN` is a fake 16 min; the time is the number of calls/ends covered, not a sleep | **KEEP** (security boundary: it asserts nothing leaks) | n/a |
| 9 | `tests/fred_rate_limit.rs` (27.9 s binary; the `backs_off_2_then_4` pair 7.3 + 7.2 s, 4 `throttle_wait`/`retry_after_wins` tests 5-6 s each) | e | Fred never shows a throttled or failed fetch as "0 unread" / "No meetings"; 429/Retry-After/backoff 2, 4, 8 s with jitter | `google_fred_sources::consecutive_throttles_back_off_exponentially` (6.7 s) checks the same backoff for the Google sources, a different code path | **PROTECTED**: invariant "user-approved" in the header; first commit #220 | real seconds: the file's header says paused tokio time races wiremock's real sockets, so it waits real 2 s and 4 s; asserts `>= Duration::from_secs(2)` | **SPEED-UP**: an injectable backoff base (a test base of 20-50 ms instead of 2 s) behind the same assertions in ratio form, or run with more binary-level parallelism (nextest does this) | about 15-20 s of this binary's 28 s if the clock were injectable; none from nextest alone beyond parallelism |
| 10 | `tests/terminal_text_delivery`, `terminal_text_redaction`, `terminal_text_memory` (29.7 + 33.5 + 9.2 s; the "megabyte of lines" and "rows of emoji" tests 5.7-8.1 s each) | e | Redaction of a `curl` command continued across lines/calls, hidden/invisible runs, memory caps (`random_control_soup_never_exceeds_the_caps`) | each of the three binaries covers a different layer (delivery, redaction, memory) | **PROTECTED**: #326 pure text engine and #334 "redaction follow-ups: invisible/fullwidth evasion" | CPU-bound on megabyte inputs | **KEEP**; a smaller input (a tenth of a megabyte) may still cross the same chunk boundary: not verified | not estimated |
| 11 | `tests/mcp_terminal_guards.rs` (29.1 s for 37 tests) | b/e | MCP refusals (-32002) and pane protection (#323) | none identified | #323 message mentions refusals; not checked per test | not examined | **KEEP** | n/a |
| 12 | `tests/ipc_peer_gating.rs` (28.8 s, 196 tests; one test 5.8 s) | c | Transport tagging: TCP peers never get Teri/Fred data, wire contract for `work` (#213) | none identified | **PROTECTED**: #213 FND-1 (security) | not examined | **KEEP** (security) | n/a |
| 13 | lib `unittests src/lib.rs` (69.3 s, 4,309 tests) | mixed | The bulk of unit tests | n/a | n/a | rows 3-8 are the long tail (about 60-80 s of per-test time under contention) | **SPEED-UP** via rows 3-6; **KEEP** the rest | up to about 20 s |
| 14 | `terminal_follow`, `terminal_follow_tools`, `approvals_wire`, `approvals_guard`, `approvals_preview` (16.7 + 18.6 + 16.9 + 8.4 + 8.1 s) | b/c | Terminal follow delivery ordering, approval wire/guard contracts; `a_hung_file_system_never_stalls_the_next_request` (5.2 s) | none identified | not checked per test; approvals files are security-adjacent | `approvals_preview` waits on a hung-file-system simulation | **KEEP** | n/a |

### 3.2 Mac

| # | Item (mean time over 3 runs) | Cat. | Protects | Covered elsewhere? | PROTECTED? | Sleeps / waits | Recommendation | Saving |
|---|---|---|---|---|---|---|---|---|
| 15 | `ReviewWebViewIntegrationTests` (364 s, 64 cases; top test 8.8 s) | b | Real `WKWebView` loads for the Perri tabbed GitHub/Jira side pane: no stray browser opens, unsent probe returns promptly, identifier store | the pane's logic tests (`ReviewPane*Tests`) cover state, not WebKit | file from #466; message has review/regression keywords (8 hits); not checked per test | `spinUntil(15-20)`, `eventually(10)`: polling waits that exit on the condition, so the time is WebKit's real load/startup, not a fixed sleep | **KEEP**; the cases share a WebKit process start per class: whether one `setUp` per class instead of per test would cut time was not tested | not estimated (largest class: 12% of all Mac test time) |
| 16 | `MotherDetailScrollTests` (167 s, 23 cases; five tests 10-30 s) | d | The job-detail scroll position stays put as sections grow and shrink; no layout storm in 200 scroller-style flips; no sideways scroll | `MotherDetailVerticalOverflowTests`, `MotherDetailSwitchTests` cover related, different properties | **PROTECTED**: first added in #325; `docs/ci.md` ties the class to a flaky history (#425) and a loop workflow | the cost is the loops (200 flips), not sleeps | **KEEP** (a known-flaky area; do not change without the loop workflow `mac-scroll-loop.yml`) | n/a |
| 17 | `FocusActivityRowSidebarTests` (129 s, 8 cases; two tests 64.5 + 50.4 s) | d | Geometry "a pinned-height helper cannot fake": the activity slot never touches anything else in a real sidebar row; flipping the mark never moves anything | none identified | file from #453 (slice B, 2 keyword hits); not checked per test | no sleeps; time is a nested loop `width x decoration x highlighted` building a new real sidebar each iteration (`makeSidebar(width:)` inside the innermost loop) | **SPEED-UP**: build the sidebar once per width and re-decorate it, as the `the very same NavTabItem instances remain` test already does for a rebuild count (line 842); asserts unchanged | estimate 40-80 s of Mac test time (the two tests are 115 s; the measurable part is sidebar construction); verify with a before/after run |
| 18 | `StagingHazardsTests.testTheDifferentialCorpusAgreesWithTheDaemonsVerdictOnEveryField` (29.4 s) | c | The Swift hazard check agrees with the daemon on every field of a corpus (wire/contract) | the Rust staging tests are the other side | **PROTECTED**: #412 (production shells; 4 keyword hits) | none | **KEEP** (a cross-language contract) | n/a |
| 19 | `WindowContentOverflowTests`, `MotherDetailVerticalOverflowTests`, `MotherOverviewAndCrewOverflowTests`, `FocusSplitOversizedChildTests`, `PerriFocusContainerLayoutTests` (37.6 + 52.5 + 28.9 + 23.3 + 51.9 s) | d | No child of the focus can make the window taller; every window size and focus shape fits (#325 and later) | overlap in spirit (all assert "window does not grow"), but each covers a different view | **PROTECTED**: #325 | resize sequences, no sleeps | **KEEP**; a sampled window-size matrix for PR vs the full matrix on a schedule is a TIER option, with the gap that a rare size could regress for a day | up to about 40 s if the matrix halves; not verified |
| 20 | `SessionRuleCardTests.testThePickRevertsAfterFifteenSeconds` and `AlwaysAllowCardTests.testThePanelRevertsAfterTheSessionPicksLifetime` (15.8 s each) | e | The card's pick reverts after `SessionRuleGesture.selectionLifetime` (15 s) | none identified | #278 / #409 (AP2a, AP4); not checked per test | **Real sleeps:** `DispatchQueue.main.asyncAfter(deadline: .now() + SessionRuleGesture.selectionLifetime + 0.5)` then `wait(for:, timeout: lifetime + 3)` | **SPEED-UP**: inject the lifetime (a test-settable value) or a clock into `SessionRuleGesture`, assert the same revert | about 31 s of Mac test time (shard 2), about 10 s after a rebalance |
| 21 | `GitHubSignedOut404HintTests` (67.4 s, 12 cases; three tests 7.7-10.6 s) | e | The signed-out 404 hint appears only for a GitHub 404, not another host, not for a stale answer | none identified | **PROTECTED**: #472 (4 keyword hits) | not examined (likely WebKit-backed like row 15) | **KEEP** | n/a |
| 22 | `ReviewPaneAccessibilityTests`, `ReviewPaneRedactionTests` (66 + 52 s) | d/c | Accessibility and redaction in the review pane | none identified | not checked | not examined | **KEEP** | n/a |
| 23 | `TrackerStructureEditingTests`, `TrackerFixupTests`, `TrackerPaneViewTests`, `TrackerEditingTests` (71.5 + 29.9 + 25 + 22.9 s) | d/e | Tracker pane editing and structure | the Rust `tracker_*` binaries cover the daemon side | tracker work is review-driven (#473, #490/#491); not checked per test | not examined | **KEEP** | n/a |
| 24 | `StagingDrawerViewTests` (56.6 s, 136 cases) | c/d | Drawer geometry and "every golden command is displayed" | none identified | #412 | none | **KEEP** | n/a |
| 25 | `ApprovalCardTests` (46.5 s, 146 cases), `ApprovalQuestionLayoutTests`, `ApprovalQuestionCardTests`, `ApprovalCardRenderTests`, `ApprovalScrollSafetyTests` (26.5 + 25.2 + 23.9 + 19.3 s) | d | The approval card: the Approve button, layout, render, scroll safety | none identified | approvals are security-adjacent (#278 and later) | not examined | **KEEP** | n/a |
| 26 | `TeriSurfaceViewTests` (46.2 s, 55 cases; three tests 8.6-10.6 s) | d | The Teri surface keeps its strip and fits small windows; the conflict probe sees an unsatisfiable constraint | the constraint-probe is a meta-test (it proves the probe works) | **PROTECTED** probable (the probe test pins a past constraint conflict, see `docs/ci.md` on `Unable to simultaneously satisfy`); not checked per test | none | **KEEP** | n/a |
| 27 | `PlanDisplayLimitsTests` (37.4 s; two tests 11.2 + 9.5 s) | d | Plans are truncated at the limits; a truncated plan builds only the rows near the viewport (a performance pin) | none identified | not checked | none | **KEEP** | n/a |
| 28 | `PaneBlankDetectorTests` (35.3 s, 79 cases) | e | Blank-pane detection (`docs/pane-blank-capture.md`) | none identified | not checked | not examined | **KEEP** | n/a |
| 29 | `ToolsOfflineAppStoreTests` (21.6 s, 5 cases; two tests 10-11 s) | e | The pace-bars badge shows only for the active focus session once its tools are offline; a lost bridge shows after a grace period | none identified | not checked | likely real waits (grace period) but not confirmed | **SPEED-UP candidate**: check whether the "grace period" is an injected clock; if real, inject | up to about 20 s if the waits are real |

### 3.3 Python (CI: 309 s total; per-test approximate)

| # | Item | Cat. | Protects | Covered elsewhere? | PROTECTED? | Sleeps / waits | Recommendation | Saving |
|---|---|---|---|---|---|---|---|---|
| 30 | `scripts/qa/tests` (196.5 s, 315 tests) | b | The QA shell scripts (Teri/Fred smoke, background wake, mother crew/hold, smoke signals, terminal guards, lint) against a fake app CLI | `tests/qa_instance` (18.6 s) tests the QA shell helpers, not the scripts | from #502: no test is removed; the scripts are the QA harness itself | `QA_SLEEP_SCALE` is already honoured in tests (#502 found no pointless sleeps); cost is process spawns (one Python process per fake CLI call) | **SPEED-UP**: run per file in parallel (`scripts/python-test-parallel.sh` exists; per-file split already implemented), bounded by `test_teri_fred_smoke` (about 66 s, setUpModule launches about 15 QA scripts at once) | about 100 s of the suite's 196 s if three or four workers fit the runner; the macos-latest core count was not measured |
| 31 | `tests/fake_mother` (41.5 s, 48 tests) | b | A real fake Mother broker (`test_fake_mother_broker`: answer-by-option 2.9 s etc.) | `tests/mother_contract` (2.2 s) checks the contract statically | not checked | process spawn | **KEEP**; parallelise with the rest | part of the same parallel saving |
| 32 | `tests/qa_instance` (18.6 s), `fake_claude_perm` (15.4 s), `operator_pin` (12.4 s: `codesign`/`lipo`), `mother_policy` (6.9 s), `ci_remote` (4.6 s) | b/c | QA instance shell functions; a fake `claude` permissions flow; the operator pin; Mother policy; the `ci-remote` tool | none identified | `operator_pin` is a security gate | process spawn | **KEEP**; `operator_pin` needs macOS tools, so it stays on the macOS job | n/a |

Items 33-40 would be the next Mac classes (`PaneBlankDetectorTests`, `AuthoredPrMergeAppearanceTests` 32.6 s, `PerriRowControlsRenderTests` 23.2 s, `MotherDetailSwitchTests` 20.3 s, `TrackerScrollSafetyTests` 20.0 s, `PlanDocumentViewTests` 18.4 s, `TaskOutputViewTests` 18.3 s, `AppControlTrackerTests` 18.3 s) and the next Rust binaries (`claude_login` 11.4 s, `google_fred_sources` 10.2 s, `tracker_two_way` 9.4 s): none were examined individually; all are **KEEP** by default, because this audit has no evidence to move them.

**RETIRE-CANDIDATE: none.** No item in the top ~40 meets the bar (duplicate of a named test, tests removed code, or asserts nothing another test does not). Row 9 and the Google-source test share a backoff idea but cover different code. Rows 3-5 overlap in setup, not assertions.

## 4. System-level levers

### 4.1 cargo-nextest in the Rust job

Measured: 345 s of execution in the sandbox against 635 s in CI under libtest (the same 4-vCPU shape; different runner hardware and an unoptimised-debuginfo-off build, so treat the ratio, 0.54, as indicative, not exact). Sum of libtest binaries 630 s, critical single binary 79 s: libtest runs binaries serially, so the floor is the sum; nextest's floor is the 1,380 s of per-test work divided by 4 cores = 345 s, and it hit that floor. Estimated saving: **about 290 s (about 32% of the Rust job)**; the job would be about 620 s. Nothing more can come from nextest on 4 cores; more cores (a larger runner) would scale it.

Risks: (1) nextest runs each test in its own process, so a test that relies on in-process state shared with another test would fail: all 9,527 passed in the sandbox, one run; flakiness over repeated runs was not measured. (2) Nextest does not run doc tests; keep `cargo test --doc` (4 s, 1 test). (3) The workflow needs an install step (`taiki-e/install-action` or the prebuilt `curl` used here); a toolchain pin policy test exists (`tests/ci_policy/test_rust_toolchain_pin.py`) and a new tool should get the same pinning discipline. (4) The sandbox build (2 m 20 s) and CI's (4 m 11 s) differ in debuginfo, so a CI run is needed to confirm the total.

### 4.2 Splitting Rust into two jobs

With nextest saturating 4 cores, a split would only help through more total cores. `--partition count:1/2` then halves execution (about 345 s to about 175 s each) but the 250 s build repeats in each job (the workflow deliberately has no cargo cache; #517's analysis), so the job would be about 430 s against about 620 s for one nextest job: about 190 s more, for about 4 extra billed minutes per run. Not worth it while the Mac shards (about 1,350 s) are the critical path. If it is ever wanted, nextest `archive` shares one build.

### 4.3 Seed counts behind an env var

| Test | Count today | Configurable? | Time (nextest, contended) |
|---|---|---|---|
| `tracker_concurrency::four_hundred_interleavings_lose_no_edit` | 400 interleavings | yes: `TRACKER_FUZZ_COUNT`, `TRACKER_FUZZ_START`, `TRACKER_FUZZ_SEED` | 47.6 s |
| `queue_tests` race tests (4 tests) | `RACE_SEEDS = 1000` | no (a `const`) | 25 s together |

A CI count has to be at least as strong as the failures it already caught: the tracker file's named-seed tests (for example seed `7a126120`) are counterexamples that run regardless of the count, so they stay on every PR. Proposal: PR runs `TRACKER_FUZZ_COUNT=100` (about 36 s of CPU saved; about 9 s of wall under nextest, or about 55 s on the 79 s libtest binary) and leaves the queue race at 1,000 (6 s of 4-core wall, and the `catches` tests rely on a high catch count: "caught in N of 1000 seeds"); a scheduled job runs `TRACKER_FUZZ_COUNT=5000` and a new `QUEUE_RACE_SEEDS=5000` (Perri's depth). What 100 interleavings would still catch was not measured: it needs a mutation run of the oracle at that count, which is the first step of the follow-up job in §5. Until then the count in CI stays 400.

### 4.4 Mac shard rebalancing

How it works today: `macOS/ci/mac-shards.json` has `shards: 3`, `balanced_from: 42353503588`, `expected_min_executed: 7614`; shards 1 and 2 list classes (`-only-testing`), shard 3 is the catch-all (`-skip-testing` of the others'). `scripts/mac_shards.py regenerate --log <concatenated logs> --balanced-from <run> --floor <n> --write` balances greedily by per-class duration, deterministic. `docs/ci.md` already says to rebalance when shards are more than about 15% apart. From the three logs here: current per-class sums 946 / 891 / 1,072 s (the slowest is 20% over the fastest), greedy equal split 970 / 970 / 970 s. Estimated saving: **about 100 s** on the slowest shard's test time. The procedure needs the three shard logs from one `main` run (artifact `mac-test-log-shard-N`, which exist for `main` pushes); the floor must be raised to about 97% of the sum of the three shards' `executed` (about 10,134 for the counts above; the current 7,614 is stale and guards little). Residual risk: the run-to-run spread of one shard's wall time is about 150-500 s, which dwarfs the gain in any single run, so judge the change over five or more runs.

### 4.5 QA script speedups

`QA_SLEEP_SCALE=0` is already honoured in tests (#502). The remaining cost in `scripts/qa/tests` is process spawns, one Python process per fake-CLI call (about 85 per script run per #502). Options, in order of cheapness: (1) run the slow Python suites in parallel (`python-test-parallel.sh`, already on main); (2) a persistent fake-CLI process instead of one per call (a code change in `scripts/qa/lib/smoke.py`; not estimated); (3) `test_teri_fred_smoke`'s `setUpModule` launching about 15 scripts concurrently is the longest single item (about 66 s attributed) and is the bound for the parallel plan. #502 saw this module trip the 120 s harness timeout on a loaded host; `QA_HARNESS_TIMEOUT` exists.

### 4.6 Tiering design (no workflow is changed here)

- **PR gate (fast):** `Rust format`, `Rust clippy`, Rust tests under nextest with the CI seed counts and the named-seed pins, three Mac shards (rebalanced), Kit, iOS build, Python tests (parallel). Nothing here is dropped; the changes are mechanical and the Mac shards stay the critical path.
- **Merge / nightly:** full seed ranges (`TRACKER_FUZZ_COUNT` and the queue seeds at 5,000+), and, if wanted, a larger Mac window-size matrix. A scheduled workflow can open an issue on failure (not designed here).
- **The gap tiering opens:** a bug only a seed above the CI count finds would reach `main` and be found within a day; the stated mitigation is the named-seed pins (every counterexample found so far is pinned and runs on every PR).
- **Merge queue and branch protection:** `docs/ci.md` says the required check is `Build & Lint` (the aggregate of the three Rust jobs) and `Swift tests (Mac app)` (the aggregate of the shards). A new nightly job is not a required check, so it does not change protection; anything moved from the PR path to the schedule stops gating merges. I did not read the live branch-protection settings or check whether a merge queue is enabled (§6), so any claim about the queue's interaction beyond the aggregate-check names is unverified.

## 5. Recommended follow-up jobs (ordered)

| # | Job | Cap | CI time saved | Risk |
|---|---|---|---|---|
| 1 | Regenerate `mac-shards.json` from the logs of the next `main` run, raise the floor to about 10,100 | $3 | about 100 s on the critical path | Low; the documented procedure |
| 2 | `cargo nextest` in `Rust tests` (plus `cargo test --doc`), measured on a branch with 5 repeated runs for flakes | $6 | about 290 s on the Rust job (not the critical path) | Medium: process-per-test; a flake review is the exit bar |
| 3 | Inject the clock in the real-wait tests: `SessionRuleGesture` and `AlwaysAllowCard` (2 x 15 s, Mac), the three `perri_pr_native` stalled-fetch tests (Rust), `fred_rate_limit` backoff base | $8 | about 31 s Mac test time (about 10 s per shard after a rebalance), 10-20 s Rust, 15-20 s `fred_rate_limit` | Low-medium: production code gets a test seam; each assertion must stay |
| 4 | Make `RACE_SEEDS` env-configurable; add a scheduled workflow at 5,000+ seeds for the tracker and queue races; first prove with a mutation run what 100 tracker interleavings still catch | $8 | 10-55 s per PR | Medium: the coverage gap in §4.6 |
| 5 | Run the slow Python suites in parallel in `Python tooling tests` (use the existing script; measure the runner's cores first) | $5 | about 100 s on the Python job | Medium: the `python-test` recipe is guarded by `tests/gates/test_python_test_split.py` and the skip allowlist |
| 6 | Re-examine `FocusActivityRowSidebarTests` (two tests, 115 s): construct the sidebar once per width | $4 | estimate 40-80 s of Mac test time | Low-medium: the assertion is geometry in real rows; verify with a before/after run |
| 7 | Investigate the Rust outlier (45187785606, 1,566 s) and the Mac shard spread (993-1,490 s for shard 3) from the step logs | $4 | unknown | Low |

**What I would not touch, and why:**

- Any tracker oracle, `StagingHazards` differential corpus, `ipc_peer_gating`, `mcp_terminal_guards` and the approvals tests: they are the security and lost-data boundaries, and their cost is mostly CPU, not waste.
- The `MotherDetail*` scroll/overflow classes: a known-flaky area (#425, `mac-scroll-loop.yml`); sampling or reordering them without that loop workflow's evidence would trade time for a recurrence.
- The two `the_..._race_test_catches...` mutation tests: they prove the race tests can fail.
- `Rust clippy` (about 130 s), Kit (about 215 s) and iOS (about 130 s): off the critical path and cheap.
- The "no DerivedData cache" and "no cargo cache" decisions in `docs/ci.md`: they were measured and chosen.

## 6. What I could not measure

- **Mac per-test times on the runner for classes outside the three logged runs:** only three `main` runs' full logs were analysed (the artifacts exist for `main` pushes; PR runs upload no log on success). Means are over three runs; no variance is reported.
- **Standalone per-test Rust times:** nextest times are under 4-way contention in a sandbox, not CI hardware. The libtest per-binary times are CI's. CI-with-nextest was not run (the workflow cannot be changed here).
- **Python per-test times:** `unittest -v` prints none. The per-test figures in §2.5 are timestamp gaps (approximate, and the first test of a suite absorbs `setUpModule`). A full local Python run was not done (disk, process count).
- **Any saving estimated from a "could be injected" change** (rows 3-6, 9, 17, 20, 29): the estimate is the test's own time, not a measured after.
- **Coverage overlap:** "covered elsewhere" is name, header and commit-message based. No coverage or mutation run was done, so "none identified" is not "none exists".
- **PROTECTED labels** are keyword matches on the first commit that added a file. They are a floor, not a proof; the per-test history (`git blame` on each test) was not read for most rows.
- **Mac classes after row 20, Rust binaries after row 14, Python suites after row 32:** not individually examined; the default is KEEP.
- **The Rust outlier run** (45187785606, 1,566 s) and the one 289 s iOS build: causes not investigated.
- **Branch protection and merge-queue settings:** not read.
- **Runner core counts:** `macos-latest` (Python job) and `macos-26` core counts were not checked, so parallel Python and any Mac in-job parallelism are unquantified. (`docs/ci.md` records that in-job parallel Mac testing failed the five-consecutive-green bar and was not shipped.)
- **The 15-minute QA suite locally and any Mac/Xcode tests locally:** not run, per the job's rules.

## 7. Methods

- **Per job/step times (§2.1, §2.2):** `gh run view <id> --repo thehammer/nostromo --json jobs`, wall = `completedAt - startedAt` per job and per step, for the ten runs listed in §2.1 (event `push`, branch `main`, from `gh run list --workflow ci.yml --branch main --event push`). Job ids for run 45257797577: Rust tests 137984090432, Python 137984090659, shards 137984262985 / 137984263330 / 137984263043.
- **Rust per-binary (§2.3):** `gh api repos/thehammer/nostromo/actions/jobs/137984090432/logs --allow-escape-sequences`; parsed `Running ... (target/...)` lines for the binary and the following `test result: ... finished in Xs` line (178 binaries, 9,528 tests, sum 630 s). Build time from `Finished test profile ... in 4m 11s` at 20:21:48 UTC.
- **Rust per-test (§2.3):** in the RWX sandbox (`rwx sandbox exec`, 4 vCPU, 15 GB), `curl -LsSf https://get.nexte.st/latest/linux | tar zxf - -C ~/.cargo/bin`, then `CARGO_PROFILE_DEV_DEBUG=0 cargo nextest run --no-fail-fast --status-level pass --final-status-level none`, output captured and the `PASS [ Ns ]` lines parsed. Result `Summary [ 345.154s] 9527 tests run: 9527 passed, 11 skipped`. One run. The sandbox was stopped afterward (`rwx sandbox stop`, confirmed by `rwx sandbox list`).
- **Mac per-class/per-test (§2.2, §2.4):** `gh run download <id> -p 'mac-test-log-shard-*' -p 'mac-shard-report-*'` for runs 45257797577, 45216673899, 45187785606; parsed `Test Case '-[NostromoTests.<Class> <test>]' passed (N seconds)` lines. Shard membership from `classes_run` in `shard-1.json` and `shard-2.json` (shard 3 is the catch-all). The greedy rebalance is a largest-first assignment to the least-loaded of three bins over the per-class mean times.
- **Python (§2.5):** the `Python tooling tests` job log of run 45257797577, `Ran N tests in Xs` after each `python3 -m unittest discover -s <dir> -v`; per-test gaps from successive `... ok` timestamps.
- **Value assessment (§3):** `git log --follow -- <file>` for the first commit, `git log -S` for specific tests, the commit message keyword scan (`perri|review|mutation|regression|pin|bug`), and reading the test source for sleeps/waits (`asyncAfter`, `thread::sleep`, `wait(for:`, `spinUntil`). Counts for context: 40 `asyncAfter`/`Thread.sleep`/`usleep`/run-loop-wait matches in 10 files under `macOS/NostromoTests`; 75 files under Rust `tests/` use `thread::sleep` or `time::sleep`. Neither count was swept for per-use cost.
- **Prior numbers reused:** #502's per-suite table (loaded host; used only for comparison), #517's Rust binary sums (732-843 s) and nextest note, `docs/ci.md` ("Where the time goes", sharding, "Measured and not shipped").
- **Not changed:** no test, workflow, Makefile or source file; nothing under `.claude/`.
