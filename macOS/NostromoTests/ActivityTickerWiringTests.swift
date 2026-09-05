import XCTest

/// Fitness functions, not behavioural tests — same spirit as
/// `TurnInteractionWiringTests` and `ImageDecodePolicyTests`. `ActivityTickerView`
/// is an `NSView` overlay and is deliberately not part of this logic-test
/// target (it needs a real window to mean anything), so the only way to
/// enforce its inviolable properties is to read it as text.
///
/// RED phase: `ActivityTickerView.swift` does not exist yet. Every test below
/// is expected to fail with a clear "file not found" `XCTUnwrap`/`String(contentsOf:)`
/// error until Cody creates it — that is the correct RED-phase result, not a
/// bug in these tests.
final class ActivityTickerWiringTests: XCTestCase {

    // MARK: - Never steals focus, scroll position, or first responder

    /// The PRD's inviolable property: an arriving activity event must never
    /// take focus, never change scroll position, and never change the first
    /// responder. Grep-level, not semantic — but a false negative here (the
    /// call site renamed to something equivalent) is far less likely than
    /// the bug this guards: someone reaching for the obvious AppKit call
    /// while wiring up the ticker's live-updating label.
    func testNeverCallsMakeFirstResponder() throws {
        let source = try Self.tickerViewSource()
        XCTAssertFalse(source.contains("makeFirstResponder"), """
            ActivityTickerView must never call makeFirstResponder — an arriving \
            activity event must never steal focus from whatever the operator is doing.
            """)
    }

    func testNeverCallsScrollToVisible() throws {
        let source = try Self.tickerViewSource()
        XCTAssertFalse(source.contains("scrollToVisible"), """
            ActivityTickerView must never call scrollToVisible — an arriving \
            activity event must never change scroll position underneath the operator.
            """)
    }

    // MARK: - Never auto-dismisses

    /// `ToastBannerView` auto-dismisses via `DispatchQueue.main.asyncAfter`
    /// (see `ToastBannerView.swift`'s `dismissWork`/`autoDismissInterval`).
    /// The ticker is explicitly NOT a toast: it stays up permanently. The
    /// presence of `asyncAfter` anywhere in the file is the concrete
    /// fingerprint of that idiom leaking back in.
    func testNeverUsesDispatchAsyncAfterTheToastAutoDismissIdiom() throws {
        let source = try Self.tickerViewSource()
        XCTAssertFalse(source.contains("asyncAfter"), """
            ActivityTickerView must never auto-dismiss — unlike ToastBannerView, \
            it is the always-visible ticker. asyncAfter is the auto-dismiss idiom's \
            fingerprint (see ToastBannerView.showToast); its presence here means the \
            toast's dismiss-after-N-seconds behaviour was copied in by mistake.
            """)
    }

    // MARK: - Sanity: the file actually defines the view

    func testDefinesAnActivityTickerViewType() throws {
        let source = try Self.tickerViewSource()
        XCTAssertTrue(
            source.contains("class ActivityTickerView") || source.contains("struct ActivityTickerView"),
            "ActivityTickerView.swift exists but does not define an ActivityTickerView type — wrong file?")
    }

    // MARK: - F4: keyed by session tag, not agent tag
    //
    // Focus.sessionTag (Models.swift) is `isBuiltIn ? agentTag :
    // "\(agentTag)-\(id.prefix(8))"` — for built-in focuses (perri, mother,
    // fred, teri) agentTag == sessionTag, so a ticker keyed by agentTag
    // looked fine by coincidence; for a project-scoped focus they differ
    // (e.g. sessionTag "claudia-C9D6B773" vs agentTag "claudia"), and the
    // daemon stamps every activity event's focus_tag with the per-session
    // tag (src/ipc/session_manager.rs's spawn_session), so an agentTag-keyed
    // ticker looks up an empty/wrong model forever for any such focus.
    func testSubscribesToActiveFocusSessionTagNotActiveFocusAgentTag() throws {
        let source = try Self.tickerViewSource()
        XCTAssertTrue(source.contains("$activeFocusSessionTag"), """
            ActivityTickerView must subscribe to $activeFocusSessionTag — keying off \
            $activeFocusAgentTag looks up the wrong (or an empty) model for any \
            project-scoped focus, where Focus.agentTag != Focus.sessionTag.
            """)
        XCTAssertFalse(source.contains("$activeFocusAgentTag"), """
            must not still subscribe to $activeFocusAgentTag — PaceBarsView and \
            StatusBarView are the intended consumers of that key, on purpose; \
            ActivityTickerView must not share it.
            """)
    }

    // MARK: - Helpers

    /// `ActivityTickerView.swift` is not compiled into this target, so it has
    /// to be read as text — same idiom as
    /// `TurnInteractionWiringTests.replViewSource()`.
    private static func tickerViewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/ActivityTickerWiringTests.swift
            .deletingLastPathComponent()                // …/macOS/NostromoTests
            .deletingLastPathComponent()                // …/macOS
            .appendingPathComponent("Nostromo/UI/ActivityTickerView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - MainLayoutActivityTickerWiringTests

/// A second, smaller fitness function: `ActivityTickerView` must actually be
/// installed somewhere, not just exist as an unused file. This does not pin
/// down Cody's exact call site (constructor args, pinning anchors) — only
/// that `MainLayout.swift` constructs one.
final class MainLayoutActivityTickerWiringTests: XCTestCase {

    func testMainLayoutConstructsAnActivityTickerView() throws {
        let url = URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/ActivityTickerWiringTests.swift
            .deletingLastPathComponent()                // …/macOS/NostromoTests
            .deletingLastPathComponent()                // …/macOS
            .appendingPathComponent("Nostromo/UI/MainLayout.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains("ActivityTickerView("), """
            MainLayout.swift must construct an ActivityTickerView — otherwise the \
            ticker exists but is never shown to the operator.
            """)
    }

    // MARK: - F4: MainLayout must also stamp the session tag
    //
    // MainLayout today only calls `AppStore.shared.setActiveFocusAgentTag(...)`
    // at its two focus-switch call sites. It must additionally (not instead)
    // call a session-tag setter with `focus.sessionTag` /
    // `activeFocus.sessionTag` at those same sites, so ActivityTickerView (see
    // ActivityTickerWiringTests above) has a correct key to subscribe to.
    // `setActiveFocusAgentTag` has its own unrelated consumers (PaceBarsView,
    // StatusBarView) keyed by agent tag on purpose, and must be left alone —
    // this is an ADDITIONAL call, not a replacement.
    func testMainLayoutCallsSetActiveFocusSessionTagWithFocusSessionTag() throws {
        let source = try Self.mainLayoutSource()

        // Tolerant proximity check, not an exact-line match — formatting
        // (line breaks, `focus.sessionTag` vs `activeFocus.sessionTag`) may
        // vary once this is actually implemented.
        let pattern = "setActiveFocusSessionTag\\([^)]{0,80}\\.sessionTag\\)"
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(source.startIndex..., in: source)
        XCTAssertGreaterThanOrEqual(regex.numberOfMatches(in: source, range: range), 1, """
            MainLayout.swift must call setActiveFocusSessionTag(...) with a \
            `.sessionTag` argument (e.g. `focus.sessionTag` or \
            `activeFocus.sessionTag`) at its focus-switch call sites — otherwise \
            ActivityTickerView has nothing correct to subscribe to, and the \
            ticker keeps looking up the wrong (or an empty) model for any \
            project-scoped focus.
            """)
    }

    func testMainLayoutStillCallsSetActiveFocusAgentTagAtLeastTwice() throws {
        // Guards against the setActiveFocusSessionTag call site ACCIDENTALLY
        // replacing the existing setActiveFocusAgentTag calls rather than
        // being added alongside them — PaceBarsView and StatusBarView still
        // depend on activeFocusAgentTag and must not regress.
        let source = try Self.mainLayoutSource()
        let occurrences = source.components(separatedBy: "setActiveFocusAgentTag(").count - 1
        XCTAssertGreaterThanOrEqual(occurrences, 2, """
            MainLayout.swift must keep calling setActiveFocusAgentTag(...) at both \
            existing focus-switch call sites — PaceBarsView and StatusBarView are \
            unrelated consumers keyed by agent tag on purpose and must not regress \
            when the new session-tag setter is added.
            """)
    }

    // MARK: - Helpers

    private static func mainLayoutSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/ActivityTickerWiringTests.swift
            .deletingLastPathComponent()                // …/macOS/NostromoTests
            .deletingLastPathComponent()                // …/macOS
            .appendingPathComponent("Nostromo/UI/MainLayout.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
