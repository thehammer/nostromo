import XCTest

/// Fitness functions, not behavioural tests — same spirit as
/// `ActivityTickerWiringTests`. The logic under test here spans
/// `AppStore.swift`, `FocusStore.swift`, and `MainLayout.swift`, none of which
/// are compiled into the `NostromoTests` logic-test target (confirmed via
/// `Nostromo.xcodeproj/project.pbxproj`'s `TestSources` build phase — those
/// three files appear only under the app target's `Sources`). So the only way
/// to enforce the wiring this fix depends on is to read the files as text.
///
/// Every assertion below is a textual heuristic, not a control-flow proof —
/// a determined refactor could rearrange the source enough to dodge one of
/// these checks while preserving (or breaking) the real behavior. They exist
/// to catch the concrete, plausible ways this fix regresses, each named in
/// its own failure message.
///
/// RED phase: none of this wiring exists in the current source, so most of
/// these assertions are expected to fail until Cody adds it — that is the
/// correct RED-phase result, not a bug in these tests. (The two scope-guard
/// tests at the bottom are the exception: they assert an ABSENCE that
/// already holds today, and must keep holding after the fix.)
final class PerFocusEvictionWiringTests: XCTestCase {

    // MARK: - AppStore.swift subscribes to FocusStore.shared.focusRemovals

    func testAppStoreSubscribesToFocusRemovals() throws {
        let source = try Self.appStoreSource()
        XCTAssertTrue(source.contains("FocusStore.shared.focusRemovals"), """
            AppStore.swift must subscribe to FocusStore.shared.focusRemovals in start() — without \
            this subscription, evictPerFocusState never runs and closing a focus leaks its \
            focusLayouts/sessionRegistry entries forever (RC1/RC2).
            """)
    }

    // MARK: - evictPerFocusState removes from BOTH per-focus dictionaries

    func testEvictPerFocusStateRemovesFromBothFocusLayoutsAndSessionRegistry() throws {
        let source = try Self.appStoreSource()
        let body = try Self.isolatedFunctionBody(named: "func evictPerFocusState", in: source, sourceFile: "AppStore.swift")
        XCTAssertTrue(body.contains("focusLayouts.removeValue"), """
            evictPerFocusState must remove the closed focus's entry from focusLayouts — omitting \
            this leaves half of the per-focus leak (RC1) unfixed.
            """)
        XCTAssertTrue(body.contains("sessionRegistry.removeValue"), """
            evictPerFocusState must remove the closed focus's entry from sessionRegistry — \
            omitting this leaves the other half of the leak, AND the RC2 daemon-resurrection \
            bug, unfixed.
            """)
    }

    // MARK: - Eviction detaches the removed session

    func testEvictionCallsDetachOnTheRemovedSession() throws {
        let source = try Self.appStoreSource()
        let lines = source.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { $0.contains("sessionRegistry.removeValue(forKey:") }) else {
            XCTFail("AppStore.swift has no sessionRegistry.removeValue(forKey:) call yet")
            return
        }
        // Proximity check, not a scope proof: the call must appear on the same
        // line as the removeValue (the expected `?.detach()` chain) or the line
        // immediately after it.
        let window = ([lines[idx]] + (idx + 1 < lines.count ? [lines[idx + 1]] : []))
            .joined(separator: "\n")
        XCTAssertTrue(window.contains(".detach()"), """
            AppStore.swift removes the session from sessionRegistry but never calls .detach() on \
            it nearby — evicting without detaching leaves the daemon-respawn loop running (the \
            RC2 resurrection bug this fix exists to close): a retained ChatSession re-issues \
            session_spawn on every daemon reconnect even after its focus/tab is gone.
            """)
    }

    // MARK: - FocusStore.remove(_:) sends focusRemovals only after mutating state

    func testFocusStoreRemoveSendsFocusRemovalsAfterMutatingAndSaving() throws {
        let source = try Self.focusStoreSource()
        let body = try Self.isolatedFunctionBody(named: "func remove(_ focus: Focus)", in: source, sourceFile: "FocusStore.swift")
        let lines = body.components(separatedBy: "\n")

        guard let mutationIdx = lines.firstIndex(where: { $0.contains("focuses.removeAll") }) else {
            XCTFail("FocusStore.remove(_:) no longer mutates focuses via focuses.removeAll — update this test if the mutation was intentionally renamed, or fix the missing mutation")
            return
        }
        guard let saveIdx = lines.firstIndex(where: { $0.contains("save()") }) else {
            XCTFail("FocusStore.remove(_:) no longer calls save() — a removal that isn't persisted reappears on next launch")
            return
        }
        guard let sendIdx = lines.firstIndex(where: { $0.contains("focusRemovals.send(") }) else {
            XCTFail("FocusStore.remove(_:) never sends focusRemovals — AppStore's eviction subscriber will never fire, so nothing prunes focusLayouts/sessionRegistry")
            return
        }

        XCTAssertLessThan(mutationIdx, sendIdx, """
            focusRemovals must be sent AFTER focuses is mutated, not before — reversing this \
            order silently reintroduces the resurrection bug: AppStore.session(for:) is a lazy \
            creator, and if the removal signal fires before the focus is actually gone from the \
            list, a caller racing the signal could recreate a session that eviction then never \
            catches. No other test catches this ordering.
            """)
        XCTAssertLessThan(saveIdx, sendIdx, """
            focusRemovals must be sent AFTER save() persists the removal, not before — sending \
            first risks a subscriber reacting to a removal that a crash before save() completes \
            would then undo, leaving eviction and persisted state disagreeing about whether the \
            focus is gone.
            """)
    }

    // MARK: - MainLayout's $focuses sink prunes viewCache

    func testMainLayoutFocusesSinkPrunesViewCache() throws {
        let source = try Self.mainLayoutSource()
        guard let start = source.range(of: "FocusStore.shared.$focuses") else {
            XCTFail("MainLayout.swift no longer subscribes to FocusStore.shared.$focuses")
            return
        }
        guard let storeRange = source.range(of: ".store(in:", range: start.upperBound..<source.endIndex) else {
            XCTFail("could not find the end of the FocusStore.shared.$focuses sink (.store(in:) not found after it)")
            return
        }
        let sinkBody = String(source[start.upperBound..<storeRange.lowerBound])

        XCTAssertTrue(sinkBody.contains("viewCache"), """
            MainLayout's $focuses sink must prune viewCache down to the live focus ids — without \
            this, closing a focus in one window leaves its NSView (and everything it retains) \
            alive forever in every OTHER window's viewCache. A per-window-only prune in \
            removeFocus is a no-op for every window except the one the operator clicked close in \
            — this is the multi-window half of the per-focus leak (RC3).
            """)
    }

    // MARK: - MainLayout's removeFocus no longer prunes viewCache itself

    func testMainLayoutRemoveFocusDoesNotItselfPruneViewCache() throws {
        let source = try Self.mainLayoutSource()
        let body = try Self.isolatedFunctionBody(named: "func removeFocus(_ focus: Focus)", in: source, sourceFile: "MainLayout.swift")
        XCTAssertFalse(body.contains("viewCache.removeValue"), """
            removeFocus must not call viewCache.removeValue itself — a per-window-only prune is \
            exactly what made the multi-window case a no-op (RC3: closing a focus in Window A \
            never freed its view in Window B). That responsibility must live only in the \
            $focuses sink now (see testMainLayoutFocusesSinkPrunesViewCache), not be duplicated \
            here.
            """)
    }

    // MARK: - Scope guard: activityModels and sessionHealth are out of scope

    /// `activityModels` eviction belongs to a different, already-queued job.
    /// Unlike `sessionHealth` (below), no legitimate `activityModels.removeValue`
    /// call exists anywhere in AppStore.swift today, so this is a safe
    /// whole-file check. It must hold both before AND after this fix — adding
    /// an eviction line here would silently widen this PR's scope into a hunk
    /// that other job owns.
    func testEvictionScopeDoesNotTouchActivityModels() throws {
        let source = try Self.appStoreSource()
        XCTAssertFalse(source.contains("activityModels.removeValue"), """
            AppStore.swift must not evict activityModels anywhere — that dictionary's eviction is \
            explicitly out of scope for this fix (it belongs to a separate, already-queued job); \
            adding an eviction line here would silently widen this PR's scope into a hunk that \
            job owns.
            """)
    }

    /// `sessionHealth.removeValue` already exists today, legitimately, inside
    /// `applySessionHealth` (clearing an entry back to the implicit-healthy
    /// default on every `.healthy` transition — unrelated to focus closure).
    /// A whole-file absence check would therefore fail against CURRENT,
    /// correct code, not just against a future scope violation — so this
    /// check is deliberately scoped to the new `evictPerFocusState` function
    /// only. `sessionHealth`'s own per-focus eviction is tracked as a
    /// separate, already-filed bug; folding it into this fix would silently
    /// widen this PR's scope into that bug's hunk.
    func testEvictionScopeDoesNotTouchSessionHealth() throws {
        let source = try Self.appStoreSource()
        let body = try Self.isolatedFunctionBody(named: "func evictPerFocusState", in: source, sourceFile: "AppStore.swift")
        XCTAssertFalse(body.contains("sessionHealth.removeValue"), """
            evictPerFocusState must not evict sessionHealth — its own per-focus eviction is a \
            separate, already-filed bug, and folding it into this fix would silently widen this \
            PR's scope into that bug's hunk. (sessionHealth.removeValue legitimately appears \
            elsewhere in this file, in applySessionHealth — this check is scoped to \
            evictPerFocusState specifically for that reason.)
            """)
    }

    // MARK: - Source helpers

    private static func appStoreSource() throws -> String { try sourceFile("Nostromo/Data/AppStore.swift") }
    private static func focusStoreSource() throws -> String { try sourceFile("Nostromo/Data/FocusStore.swift") }
    private static func mainLayoutSource() throws -> String { try sourceFile("Nostromo/UI/MainLayout.swift") }

    private static func sourceFile(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/PerFocusEvictionWiringTests.swift
            .deletingLastPathComponent()                // …/macOS/NostromoTests
            .deletingLastPathComponent()                // …/macOS
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Isolates a function's body by counting braces from its first `{` after
    /// `signature` to the matching close. A textual heuristic, not a real
    /// parser — sufficient to check "does this function's body mention X",
    /// not to prove anything about control flow or scoping precision.
    private static func isolatedFunctionBody(named signature: String, in source: String, sourceFile: String,
                                             file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let sigRange = source.range(of: signature) else {
            XCTFail("\(signature) not found in \(sourceFile) yet", file: file, line: line)
            return ""
        }
        guard let openBrace = source[sigRange.upperBound...].firstIndex(of: "{") else {
            XCTFail("\(signature) has no body in \(sourceFile)", file: file, line: line)
            return ""
        }
        var depth = 0
        var idx = openBrace
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: openBrace)..<idx])
                }
            }
            idx = source.index(after: idx)
        }
        XCTFail("could not find a matching closing brace for \(signature) in \(sourceFile)", file: file, line: line)
        return ""
    }
}
