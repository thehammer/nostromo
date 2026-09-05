import XCTest

// `DynamicFocusView.swift` is AppKit and NOT compiled into the host-less
// `NostromoTests` bundle (same reason `CodeContentViewTests.swift` treats it
// as text — see that file's header comment). These are fitness functions,
// not behavioural tests: they describe the target state of code that
// doesn't exist yet. Cody is about to rewrite large parts of
// `DynamicFocusView.swift` so that `renderedTree` can never advance past a
// repair step that actually failed (the "silent divergence" bug this branch
// fixes) — these tests are expected to FAIL against the current file; that's
// the RED phase.

/// Fitness functions pinning the shape of the reconciliation fix in
/// `DynamicFocusView.swift` (fix/detail-region-content-not-rendering).
final class DynamicFocusViewWiringTests: XCTestCase {

    // MARK: a. renderedTree is assigned in exactly one place, inside `reconcile`

    func testRenderedTreeIsAssignedInExactlyOnePlaceInsideAFunctionNamedReconcile() throws {
        let source = try Self.dynamicFocusViewSource()

        let assignmentLines = Self.lines(containing: "renderedTree = ", in: source)
        XCTAssertEqual(assignmentLines.count, 1, """
            RC2: renderedTree must be assigned in exactly one place in the whole file. Before the fix, several \
            branches of handleLayoutUpdate (and renderLayout) each advanced renderedTree independently — which is \
            exactly the bug: an incremental repair path (applyActiveTabOnly/applyTabMembership) can fail partway \
            through and the bookkeeping still advances as if it fully succeeded, so nothing ever detects the \
            divergence. Found \(assignmentLines.count) assignment(s):
            \(assignmentLines.joined(separator: "\n"))
            """)

        guard let onlyAssignmentLine = assignmentLines.first,
              let occurrence = source.range(of: onlyAssignmentLine)
        else { return }

        // Nearest preceding `func` — same "scope since the last `func`
        // keyword" approximation CodeContentViewTests.occurrencesOutsideScrollToBranch
        // uses: robust to reformatting, only fooled by another `func`
        // inserted in between, which would be a stranger change than this
        // test is trying to guard against.
        guard let precedingFunc = source.range(
            of: "func ", options: .backwards, range: source.startIndex..<occurrence.lowerBound
        ) else {
            XCTFail("RC2: no enclosing `func` found before the sole renderedTree assignment")
            return
        }
        let funcLine = source[source.lineRange(for: precedingFunc)]
        XCTAssertTrue(funcLine.contains("reconcile"), """
            RC2: the sole renderedTree assignment must live inside a function whose signature contains \
            "reconcile" — a single, named choke point for advancing the rendered-state bookkeeping is what makes \
            "did the repair actually succeed?" checkable in one place instead of scattered across every branch. \
            Enclosing func line found: \(funcLine)
            """)
    }

    // MARK: b. No bare `continue`/`return` in the guard-driven repair paths

    func testGuardDrivenRepairFunctionsHaveNoBareContinueOrReturn() throws {
        let source = try Self.dynamicFocusViewSource()
        let names = ["applyActiveTabOnly", "applyTabMembership", "replaceInPlace", "updateContent"]

        for name in names {
            let body = try Self.functionBody(named: name, in: source)
            let violations = Self.bareStatementLines(in: body)
            XCTAssertTrue(violations.isEmpty, """
                \(name) must not contain a bare `continue` or bare `return` — every failure path in it must now \
                propagate a signal (e.g. return a Bool the caller checks, or otherwise be caught) rather than \
                silently doing nothing, which is exactly how a failed repair step used to go undetected. \
                Found \(violations.count) bare occurrence(s) in \(name)'s body.
                """)
        }
    }

    // MARK: c. PaneContentNSView.update clears content in every hidden branch

    func testEveryIsHiddenTrueBranchInPaneContentNSViewUpdateAlsoClearsContent() throws {
        let source = try Self.dynamicFocusViewSource()
        let body = try Self.functionBody(named: "update", in: source, signaturePrefix: "func update(content:")
        let lines = Self.linesArray(body)

        for name in ["codeView", "conversationView", "ticketView"] {
            guard let idx = lines.firstIndex(where: { $0.contains("\(name).isHidden = true") }) else {
                XCTFail("\(name).isHidden = true not found in PaneContentNSView.update — did the branch move or rename?")
                continue
            }
            let lo = max(0, idx - 3)
            let hi = min(lines.count - 1, idx + 3)
            let vicinity = lines[lo...hi].joined(separator: "\n")
            XCTAssertTrue(vicinity.contains("\(name).clearContent()"), """
                \(name).isHidden = true must be accompanied by a \(name).clearContent() call in the same branch — \
                otherwise a pane that flips away from this content kind leaves stale content sitting behind it, \
                invisible until the pane flips back to that kind and the stale content flashes into view. \
                Vicinity checked:
                \(vicinity)
                """)
        }
    }

    // MARK: d. No bare NSSplitView() construction

    func testDynamicFocusViewConstructsNoBareNSSplitView() throws {
        let source = try Self.dynamicFocusViewSource()
        XCTAssertFalse(source.contains("NSSplitView()"), """
            DynamicFocusView must never construct a bare NSSplitView() — only RatioSplitView() may be \
            instantiated, so a future split node can't reintroduce the never-applied-ratios bug. (NSSplitView as \
            a type annotation/cast, e.g. `as? NSSplitView`, is fine — only the bare constructor call is forbidden.)
            """)
    }

    // MARK: e. applyRatios is never invoked from inside DispatchQueue.main.async

    func testApplyRatiosIsNeverInvokedInsideADispatchMainAsyncBlock() throws {
        let source = try Self.dynamicFocusViewSource()
        let blocks = Self.balancedBraceBlocks(startingAt: "DispatchQueue.main.async {", in: source)
        for block in blocks {
            XCTAssertFalse(block.contains("applyRatios"), """
                applyRatios must not be invoked from inside a DispatchQueue.main.async block — deferring to a \
                later, unconditional run-loop turn is exactly the layout-timing bug this branch fixes: the split \
                can still report zero size when that block finally runs, and a fire-and-forget async dispatch has \
                no way to notice that and retry. Offending block:
                \(block)
                """)
        }
    }

    // MARK: Bonus. replaceInPlace's result must gate the following registerTabRegion call

    func testReplaceInPlaceResultGatesTheFollowingRegisterTabRegionCall() throws {
        let source = try Self.dynamicFocusViewSource()
        let body = try Self.functionBody(named: "applyTabMembership", in: source)

        // Textual heuristic, not a control-flow proof (same honest caveat
        // CodeContentViewTests' own docstring uses): this only catches the
        // specific "two statements back to back with nothing gating the
        // second on the first's result" shape. It cannot verify that
        // whatever gating exists is correct, only that the old unconditional
        // shape is gone.
        let oldUngatedPattern = "replaceInPlace(oldRegion, with: newRegion)\n\n            registerTabRegion(newRegion"
        XCTAssertFalse(body.contains(oldUngatedPattern), """
            applyTabMembership must not call registerTabRegion(newRegion...) unconditionally immediately after \
            replaceInPlace(oldRegion, with: newRegion) now that replaceInPlace returns Bool — the call must be \
            gated (e.g. `guard replaceInPlace(...) else { ... }` or an `if` on its result). Otherwise a failed \
            in-place swap still registers tab-region bookkeeping for a view that was never actually inserted into \
            the hierarchy — the exact "bookkeeping advances as if the repair succeeded" bug.
            """)
    }

    // MARK: f. RC1 — every UserDefaults write of a saved ratio is gated by RatioPersistencePolicy

    func testTheOnlySavedRatioWriteIsGatedByRatioPersistencePolicy() throws {
        let source = try Self.dynamicFocusViewSource()

        // The corrupted-forever bug (fix-collapsed-split-ratio-persistence
        // RC1): the resize observer wrote every
        // `NSSplitView.didResizeSubviewsNotification` straight to
        // `UserDefaults` unconditionally, so an operator's observed
        // near-collapsed `[0.977, 0.022]` — once written — outranked every
        // later daemon-broadcast ratio forever. There must be exactly one
        // place in the whole file that ever writes a ratio to disk, and
        // `RatioPersistencePolicy` must be consulted somewhere before it in
        // file order — i.e. the write path actually gates on the policy
        // rather than writing unconditionally again.
        let writeLines = Self.lines(containing: "UserDefaults.standard.set(", in: source)
        XCTAssertEqual(writeLines.count, 1, """
            RC1: exactly one place in DynamicFocusView.swift may write a ratio to UserDefaults — found \
            \(writeLines.count):
            \(writeLines.joined(separator: "\n"))
            """)

        guard let onlyWriteLine = writeLines.first,
              let writeRange = source.range(of: onlyWriteLine)
        else { return }

        let precedingSource = source[source.startIndex..<writeRange.lowerBound]
        XCTAssertTrue(precedingSource.contains("RatioPersistencePolicy"), """
            RC1: RatioPersistencePolicy must be referenced (and consulted as a guard) before the sole \
            UserDefaults.standard.set(...) call that persists a ratio — otherwise the write path can still \
            persist a corrupt or transient value the way it did before this fix, with no policy check anywhere \
            upstream of it.
            """)
    }

    // MARK: g. RC3 — desiredRatios is cleared exactly once, only on a successful apply

    func testDesiredRatiosIsClearedExactlyOnceAndOnlyAfterASuccessfulApply() throws {
        let source = try Self.dynamicFocusViewSource()

        let clearLines = Self.lines(containing: "desiredRatios = nil", in: source)
        XCTAssertEqual(clearLines.count, 1, """
            RC3: desiredRatios must be cleared in exactly one place. Before D3, `RatioSplitView.layout()` cleared \
            desiredRatios unconditionally *before* calling applyRatios, so a solver refusal (e.g. the narrow-split \
            under-sum case) was indistinguishable from a successful application and the ratios were abandoned for \
            good. Found \(clearLines.count) occurrence(s):
            \(clearLines.joined(separator: "\n"))
            """)

        // The clear must sit inside a truthy-condition success branch (e.g.
        // `if applied { ... }`), not unconditional and not preceding the call
        // that produces that condition. `balancedBraceBlocks` finds every
        // `if applied {` block (brace-depth matched, so a nested closure
        // inside doesn't truncate it) and this asserts the sole clear lives
        // inside one of them.
        let appliedBlocks = Self.balancedBraceBlocks(startingAt: "if applied {", in: source)
        XCTAssertTrue(appliedBlocks.contains { $0.contains("desiredRatios = nil") }, """
            RC3: desiredRatios = nil must sit inside an `if applied { ... }` (or equivalent truthy-condition) \
            block, not unconditionally — clearing it before knowing whether applyRatios actually succeeded is \
            exactly the bug D3 fixes. Blocks found starting at "if applied {":
            \(appliedBlocks.joined(separator: "\n---\n"))
            """)

        // And that condition must itself be produced by the call to
        // applyRatios, appearing earlier in the file — not a stale/unrelated
        // `applied` flag the clear happens to piggyback on.
        if let applyCallRange = source.range(of: "DynamicFocusView.applyRatios(ratios, to: self)"),
           let ifAppliedRange = source.range(of: "if applied {") {
            XCTAssertTrue(applyCallRange.lowerBound < ifAppliedRange.lowerBound, """
                RC3: the call to applyRatios must precede the `if applied {` branch that clears desiredRatios — \
                the clear can only be gated on a result that was actually computed first.
                """)
        } else {
            XCTFail("RC3: could not locate both the applyRatios call site and the `if applied {` branch — did the shape change?")
        }
    }

    // MARK: h. RC2/D2 — makeSplitView never falls back to the bare, unvalidated saved ratios

    func testMakeSplitViewNeverFallsBackToBareUnvalidatedSavedRatios() throws {
        let source = try Self.dynamicFocusViewSource()
        let body = try Self.functionBody(named: "makeSplitView", in: source)

        // The literal old buggy line: a saved ratio, straight off disk, with
        // no validation at all, applied as-is. This is precisely how a
        // corrupted `[0.977, 0.022]` became authoritative forever — it must
        // always be routed through RatioPersistencePolicy (and a count check
        // against the split's actual child count) before ever reaching
        // `desiredRatios`.
        XCTAssertFalse(body.contains("savedRatios ?? ratios"), """
            RC2/D2: makeSplitView must not contain the bare `savedRatios ?? ratios` fallback — a saved ratio must \
            be validated (via RatioPersistencePolicy plus a child-count check) before it can ever be trusted over \
            the agent-supplied defaults.
            """)
    }

    // MARK: j. Second-pass adherence finding — the resize observer must run synchronously, not on an async queue

    func testResizeObserverIsRegisteredSynchronouslyNotOnAnAsyncMainQueue() throws {
        let source = try Self.dynamicFocusViewSource()
        let body = try Self.functionBody(named: "makeSplitView", in: source)

        // `RatioSplitView.layout()` sets `isApplyingProgrammatically`, calls
        // `applyRatios`, and clears the flag again — all synchronously
        // within one run-loop turn. An observer registered with `queue:
        // .main` runs as a *deferred, async* block: by the time it actually
        // executes, the flag has already been reset to `false`, so
        // `RatioPersistencePolicy.shouldPersist`'s `isProgrammatic` check
        // silently never fires in production — a fresh launch with no saved
        // ratio key writes one to disk on the very first daemon-driven
        // layout, exactly the bug `RatioPersistencePolicyTests` couldn't
        // catch because it only calls the pure policy function directly.
        // `queue: nil` runs the block synchronously on the posting thread
        // (main, for an NSSplitView layout pass), which is what makes the
        // flag observable while it's still true.
        XCTAssertFalse(body.contains("queue: .main"), """
            Second-pass finding: the didResizeSubviewsNotification observer in makeSplitView must not be \
            registered with `queue: .main` — that defers the block to a later, async run-loop turn, by which \
            time RatioSplitView.layout() has already synchronously cleared isApplyingProgrammatically back to \
            false. The isProgrammatic guard becomes a permanent no-op and a fresh launch persists a ratio nobody \
            dragged.
            """)
        XCTAssertTrue(body.contains("queue: nil"), """
            Second-pass finding: the didResizeSubviewsNotification observer in makeSplitView must be registered \
            with `queue: nil` so it runs synchronously on the posting thread and can actually observe \
            isApplyingProgrammatically/isDraggingDivider at the moment they're true.
            """)
    }

    // MARK: k. Second-pass adherence finding — persistence is gated on an actual divider-drag signal

    func testShouldPersistIsGatedByAnActualDividerDragSignal() throws {
        let source = try Self.dynamicFocusViewSource()

        // The pre-existing signature (`ratios`, `total`, `isProgrammatic`)
        // had no way to distinguish an operator's divider drag from a window
        // resize, a fullscreen transition, or a display reconfiguration —
        // all of which fire the exact same didResizeSubviewsNotification
        // and are equally non-programmatic. Persistence must be gated on a
        // real positive "a divider is under the mouse right now" signal.
        let makeSplitViewBody = try Self.functionBody(named: "makeSplitView", in: source)
        XCTAssertTrue(makeSplitViewBody.contains("isUserDrag: split.isDraggingDivider"), """
            Second-pass finding: makeSplitView's call to RatioPersistencePolicy.shouldPersist must pass \
            `isUserDrag: split.isDraggingDivider` — without it, a window resize/fullscreen toggle/display \
            reconfiguration (none of which are "isProgrammatic") persists a ratio nobody dragged.
            """)

        let mouseDownBody = try Self.functionBody(named: "mouseDown", in: source, signaturePrefix: "override func mouseDown(")
        XCTAssertTrue(mouseDownBody.contains("isDraggingDivider = true"), """
            Second-pass finding: RatioSplitView.mouseDown(with:) must set isDraggingDivider = true for the \
            duration of the divider-drag tracking loop — this is the only reliable "an operator actually grabbed \
            a divider" signal, since NSSplitView only routes mouseDown to the split view itself when the hit \
            point falls in the divider gap between arranged subviews, never inside a child view.
            """)
    }

    // MARK: i. D4 — currentRatios normalizes against child extents, never the split's own bounds

    func testCurrentRatiosNeverNormalizesAgainstTheSplitsOwnBounds() throws {
        let source = try Self.dynamicFocusViewSource()
        let body = try Self.functionBody(named: "currentRatios", in: source)

        // The split's own `bounds` also includes divider thickness, which
        // belongs to no child — normalizing against it is exactly what
        // produced the systematic under-sum (observed: 0.9995, 0.9993,
        // 0.9994) that could trip RatioSolver's `abs(sum - 1.0) < 0.01`
        // tolerance on a narrow split. D4 requires normalizing against the
        // *sum of the children's own extents* instead.
        XCTAssertFalse(body.contains("split.bounds"), """
            D4: currentRatios must not reference split.bounds — it must normalize against the sum of the \
            children's own extents, not the split's full bounds (which includes divider thickness belonging to \
            no child). Body:
            \(body)
            """)
        XCTAssertFalse(body.contains(".bounds.size"), """
            D4: currentRatios must not reference any view's .bounds.size when computing the returned ratios — \
            only child frame extents (summed) may be used as the normalization denominator. Body:
            \(body)
            """)
    }

    // MARK: f. M1 regression — one-shot deferred ratio apply must not return

    /// Pins the pre-#122 defect fixed by `RatioSplitView`: `makeSplitView`
    /// used to apply ratios via a one-shot `DispatchQueue.main.async` block
    /// that was fresh-launch-conditioned — it could fire on the one
    /// run-loop turn where the split still reported zero size, and because
    /// it only ran once, the agent-authored (or operator-dragged) ratios
    /// were silently abandoned forever. This is a diagnostics-only branch
    /// (no fix here) but this regression must not silently come back while
    /// unrelated work touches this file.
    func testMakeSplitViewNeverGoesBackToAOneShotDeferredRatioApply() throws {
        let source = try Self.dynamicFocusViewSource()

        let body = try Self.functionBody(named: "makeSplitView", in: source)
        // Matched with the trailing "{", not the bare "DispatchQueue.main.async"
        // substring — same idiom testApplyRatiosIsNeverInvokedInsideADispatchMainAsyncBlock
        // uses below, and for the same reason: this function's body legitimately
        // contains a doc comment *mentioning* DispatchQueue.main.async (in
        // backticks, explaining why it's no longer used), which a bare substring
        // check would misfire on.
        XCTAssertFalse(body.contains("DispatchQueue.main.async {"), """
            Pinning M1: makeSplitView must not apply ratios via a one-shot DispatchQueue.main.async \
            dispatch — see this test's doc comment for why that's exactly the pre-#122 "ratios \
            silently abandoned forever" bug. Must not regress.
            """)

        XCTAssertTrue(source.contains("final class RatioSplitView"), """
            Pinning M1: DynamicFocusView.swift must still define RatioSplitView — the type that \
            replaced the one-shot deferred apply. Must not regress.
            """)
        let ratioSplitViewBody = try Self.classBody(named: "RatioSplitView", in: source)
        XCTAssertTrue(ratioSplitViewBody.contains("override func layout()"), """
            Pinning M1: RatioSplitView must keep retrying ratio application on every layout() pass \
            (rather than a single deferred dispatch) so it can never abandon ratios just because the \
            split had zero size on one particular run-loop turn. Must not regress.
            """)
    }

    // MARK: g. M2 regression — silent content-push drop must not return

    /// Pins the pre-#122 defect where `updateContent` silently dropped a
    /// content push for a pane id it couldn't find a materialised view for
    /// (the old bare `continue`) — a diverged hierarchy would eat the push
    /// with zero trace of it ever happening. This is a diagnostics-only
    /// branch (no fix here) but this regression must not silently come back.
    func testUpdateContentLogsAMissInsteadOfSilentlyDroppingIt() throws {
        let source = try Self.dynamicFocusViewSource()
        let body = try Self.functionBody(named: "updateContent", in: source)

        // updateContent is already one of the four functions
        // testGuardDrivenRepairFunctionsHaveNoBareContinueOrReturn checks for
        // bare continue/return — re-asserting it here documents *why* it
        // matters for this specific function (M2) rather than re-deriving
        // the check differently.
        let violations = Self.bareStatementLines(in: body)
        XCTAssertTrue(violations.isEmpty, """
            Pinning M2: updateContent's miss branch (no materialised view for a pane id paneContent \
            names) must not silently drop the push via a bare continue. Must not regress. \
            Found \(violations.count) bare occurrence(s).
            """)

        XCTAssertTrue(body.contains(".error("), """
            Pinning M2: updateContent's miss branch must now log at .error level when it can't find \
            a materialised view for a pane id paneContent names — before #122 this branch did \
            nothing at all, so a diverged hierarchy silently ate the content push with no trace. \
            Must not regress.
            """)
    }

    // MARK: h. Tripwire is wired in

    func testPaneFirstPaintAuditTripwireIsWiredIntoPaneContentNSView() throws {
        let source = try Self.dynamicFocusViewSource()

        let paneContentBody = try Self.classBody(named: "PaneContentNSView", in: source)
        XCTAssertTrue(paneContentBody.contains("override func layout()"), """
            PaneContentNSView must override layout() to run the PaneFirstPaintAudit tripwire — \
            the tripwire must not be removable without this test noticing.
            """)
        XCTAssertTrue(source.contains("PaneFirstPaintAudit"), """
            DynamicFocusView.swift must reference PaneFirstPaintAudit — the tripwire must not be \
            removable without this test noticing.
            """)
    }

    // MARK: i. Ratio machinery untouched (sequencing guard, not correctness guard)

    /// This is a *sequencing* guard, not a correctness guard: it only checks
    /// that these three symbols still exist by name, not that their
    /// behaviour is unchanged, and it has no tooling here to diff against a
    /// base branch. `.claude/plans/fix-collapsed-split-ratio-persistence.md`
    /// is a separately-queued job that owns and is actively rewriting the
    /// ratio machinery in this same file — if this fails, the useful
    /// question is "did that work collide with the diagnostics added here?",
    /// not "which side is wrong?".
    func testRatioMachinerySymbolsStillExistSequencingGuardOnly() throws {
        let source = try Self.dynamicFocusViewSource()

        let sequencingGuardMessage = """
            Sequencing guard, not a correctness guard — see \
            .claude/plans/fix-collapsed-split-ratio-persistence.md, a separately-queued job that \
            owns and is actively rewriting the ratio machinery in this same file. This symbol's \
            presence is necessary-but-not-sufficient evidence nothing here collided with that work.
            """
        XCTAssertTrue(source.contains("fileprivate static func applyRatios"), sequencingGuardMessage)
        XCTAssertTrue(source.contains("private static func currentRatios"), sequencingGuardMessage)
        XCTAssertTrue(source.contains("final class RatioSplitView"), sequencingGuardMessage)
    }

    // MARK: l. W1 — render-state-visibility: reconcile reports what it just rendered

    /// Pins the W1 render-state-visibility wiring: `reconcile` must report
    /// the pane ids the view hierarchy *actually holds* to the daemon (via
    /// `AppStore.shared.client.reportRenderedShape`), sourced from
    /// `leafViews.keys` — the same value the `updateContent` MISS-log line
    /// calls "rendered" — never from `expected` (== `PaneRenderPlan.build(from:
    /// model.tree)`), which is merely what this reconcile *attempted* to
    /// build. Reporting `expected` would make the tool agree with itself by
    /// construction and hide exactly the materialisation failures (a leaf
    /// that silently never made it into `leafViews`) it exists to catch. And
    /// critically: the sole `renderedTree = ` assignment site (test a. above)
    /// must still be exactly one — this feature must not need a second one.
    func testReconcileReportsRenderedShapeFromActualLeafViewsNotExpected() throws {
        let source = try Self.dynamicFocusViewSource()
        let body = try Self.functionBody(named: "reconcile", in: source, signaturePrefix: "private func reconcile(")

        XCTAssertTrue(body.contains("reportRenderedShape("), """
            W1: DynamicFocusView.reconcile must call reportRenderedShape (on AppStore.shared.client) so the \
            daemon learns what this window actually materialised — without it, nostromo.get_render_state has \
            nothing to compare its expected tree against for this window.
            """)

        // The report's pane ids must come from what the hierarchy actually
        // holds (leafViews.keys) — not from `expected`, which is only what
        // this reconcile attempted to build and would trivially "agree" even
        // when a leaf silently failed to materialise.
        XCTAssertTrue(body.contains("paneIds: Array(leafViews.keys)"), """
            W1: the RenderedShape report must be built from `leafViews.keys` — the view hierarchy's actual, \
            current state — not from `expected` (what reconcile attempted to build). Reporting `expected` makes \
            the divergence this tool exists to catch unreportable by construction.
            """)
        XCTAssertFalse(body.contains("paneIds: expected.paneIds"), """
            W1: the RenderedShape report must not be built from `expected` — that is what was *requested*, not \
            what was actually rendered, and reporting it would make nostromo.get_render_state agree with itself \
            by construction instead of catching real materialisation failures.
            """)

        // The single-assignment-site invariant from test (a) must survive
        // this addition — asserted again here, directly in this test's own
        // failure message, so a regression that adds a second assignment
        // site while wiring the report through is attributed to this
        // feature rather than surfacing only as test (a)'s unrelated-looking
        // failure.
        let assignmentLines = Self.lines(containing: "renderedTree = ", in: source)
        XCTAssertEqual(assignmentLines.count, 1, """
            W1: adding the RenderedShape report must not introduce a second renderedTree assignment site. Found \
            \(assignmentLines.count): \(assignmentLines.joined(separator: "\n"))
            """)
    }

    // MARK: - Helpers

    private static func dynamicFocusViewSource() throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent("UI/Views/DynamicFocusView.swift"), encoding: .utf8)
    }

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/macOS/NostromoTests/DynamicFocusViewWiringTests.swift
            .deletingLastPathComponent()          // …/macOS/NostromoTests
            .deletingLastPathComponent()          // …/macOS
            .appendingPathComponent("Nostromo")
    }

    /// Every line containing `needle`, in order.
    private static func lines(containing needle: String, in source: String) -> [String] {
        source.components(separatedBy: "\n").filter { $0.contains(needle) }
    }

    private static func linesArray(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Every line in `body` that contains a bare (no-argument) `continue` or
    /// `return` statement — whether it sits alone on its own line
    /// (`            continue`) or inline inside a single-line guard
    /// (`else { continue }`). Splitting each line on `{`/`}`/`;` first turns
    /// both shapes into the same "is one of this line's statements exactly
    /// `continue`/`return`?" question, so this isn't fooled by a same-line
    /// `guard ... else { return }` the way a plain whole-line-trim check
    /// would be — and it still lets `return someValue` or `return isValid`
    /// through unflagged, since neither trims down to exactly `continue` or
    /// `return`.
    private static func bareStatementLines(in body: String) -> [String] {
        linesArray(body).filter { line in
            let statements = line
                .components(separatedBy: CharacterSet(charactersIn: "{};"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return statements.contains("continue") || statements.contains("return")
        }
    }

    /// Every balanced `{ ... }` block starting at `marker` (which must itself
    /// end in `{`), matching brace depth so a nested block doesn't truncate
    /// the match. Mirrors `CodeContentViewTests.balancedCalls`, but for
    /// braces instead of parens.
    private static func balancedBraceBlocks(startingAt marker: String, in source: String) -> [String] {
        var blocks: [String] = []
        var searchStart = source.startIndex
        while let markerRange = source.range(of: marker, range: searchStart..<source.endIndex) {
            var depth = 1   // `marker` already includes the opening "{"
            var idx = markerRange.upperBound
            while idx < source.endIndex, depth > 0 {
                if source[idx] == "{" { depth += 1 }
                if source[idx] == "}" { depth -= 1 }
                idx = source.index(after: idx)
            }
            blocks.append(String(source[markerRange.lowerBound..<idx]))
            searchStart = idx
        }
        return blocks
    }

    private struct SourceScanError: Error, CustomStringConvertible {
        let description: String
    }

    /// The body (from the opening `{` to its matching closing `}`) of the
    /// function whose signature starts with `signaturePrefix` (defaulting to
    /// `func <name>(`) — brace-depth matched so a nested closure inside the
    /// function doesn't truncate the extraction.
    private static func functionBody(
        named name: String, in source: String, signaturePrefix: String? = nil
    ) throws -> String {
        let marker = signaturePrefix ?? "func \(name)("
        guard let sigRange = source.range(of: marker) else {
            throw SourceScanError(description: "'\(marker)' not found in DynamicFocusView.swift — did it move or rename?")
        }
        guard let braceStart = source.range(of: "{", range: sigRange.upperBound..<source.endIndex) else {
            throw SourceScanError(description: "no opening brace found after '\(marker)'")
        }
        var depth = 1
        var idx = braceStart.upperBound
        while idx < source.endIndex, depth > 0 {
            if source[idx] == "{" { depth += 1 }
            if source[idx] == "}" { depth -= 1 }
            idx = source.index(after: idx)
        }
        return String(source[braceStart.lowerBound..<idx])
    }

    /// The source text of the class declaration named `name` (matches
    /// `class <name>` whether or not it's prefixed `final`), from the
    /// declaring line up to (but not including) the next top-level
    /// `class`/`final class` declaration, or the end of the file if there
    /// isn't one. Textual, not brace-depth matched like `functionBody` —
    /// sufficient for "does this class's source text contain X" checks,
    /// not a structural proof of where the class actually ends.
    private static func classBody(named name: String, in source: String) throws -> String {
        guard let classRange = source.range(of: "class \(name)") else {
            throw SourceScanError(description: "'class \(name)' not found in DynamicFocusView.swift — did it move or rename?")
        }
        let rest = source[classRange.upperBound...]
        let nextClassStart = [
            rest.range(of: "\nclass ")?.lowerBound,
            rest.range(of: "\nfinal class ")?.lowerBound,
        ].compactMap { $0 }.min() ?? rest.endIndex
        return String(source[classRange.lowerBound..<nextClassStart])
    }
}
