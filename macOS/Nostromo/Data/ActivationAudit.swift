import AppKit
import os

/// Diagnostic only: one log line per place Nostromo activates the app or orders a window front,
/// plus the system events around them (activation, Space and screen changes). No behaviour.
///
/// Lines go to the placement log (`~/.nostromo/logs/window-placement.log`, scope `activation`) and
/// the unified log (subsystem `com.hammer.nostromo.mac`, category `WindowPlacement`). Correlate
/// by timestamp with `scripts/debug/space-watch.sh`; see `docs/activation-audit.md`.
///
/// Privacy: the line carries the call-site reason, flags, display UUIDs and window counts/states
/// only. Never window titles, text, or conversation ids. A source scan test requires an
/// `ActivationAudit.note` before every activate / order-front call in the app target.
enum ActivationAudit {

    /// One window as the audit sees it. Deliberately has no title field.
    struct WindowInfo: Equatable {
        let number: Int
        let displayUUID: String
        let isVisible: Bool
        let isKey: Bool
        /// `NSWindow.OcclusionState.rawValue`; bit 2 (value 2) is "visible".
        let occlusion: UInt
    }

    /// Log one line just before an activation / order-front. `reason` names the call site (and
    /// trigger); `detail` is a short static note such as a request command name, never content.
    static func note(_ reason: StaticString, detail: String = "",
                     file: StaticString = #fileID, line: UInt = #line) {
        emit("\(reason)", detail: detail, site: "\(file):\(line)")
    }

    /// Log a system event (observer callbacks) with the same fields.
    static func event(_ reason: String, detail: String = "") {
        emit(reason, detail: detail, site: nil)
    }

    /// Observers added once at launch.
    static func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let nc = NotificationCenter.default
        let pairs: [(NotificationCenter, Notification.Name, String)] = [
            (nc, NSApplication.didBecomeActiveNotification, "didBecomeActive"),
            (nc, NSApplication.didResignActiveNotification, "didResignActive"),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification, "activeSpaceDidChange"),
            (nc, NSApplication.didChangeScreenParametersNotification, "didChangeScreenParameters"),
            (nc, NSWindow.didChangeScreenNotification, "window.didChangeScreen"),
            (nc, NSWindow.didChangeOcclusionStateNotification, "window.didChangeOcclusionState"),
        ]
        for (center, name, label) in pairs {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                if name == NSWindow.didChangeScreenNotification || name == NSWindow.didChangeOcclusionStateNotification,
                   !(note.object is NostromoWindow) { return }
                event(label)
            }
        }
    }

    /// The pure formatter, so tests can pin the fields without AppKit state.
    static func format(reason: String, detail: String, site: String?, appActive: Bool,
                       caller: String, keyDisplay: String?, windows: [WindowInfo]) -> String {
        var parts = ["reason=\(reason)"]
        if let site { parts.append("site=\(site)") }
        if !detail.isEmpty { parts.append("detail=\(detail)") }
        parts.append("caller=\(caller)")
        parts.append("appActive=\(appActive)")
        parts.append("keyDisplay=\(keyDisplay ?? "none")")
        let list = windows.map {
            "#\($0.number)@\($0.displayUUID) visible=\($0.isVisible) key=\($0.isKey) occ=\($0.occlusion)"
        }.joined(separator: "; ")
        parts.append("windows=[\(list)]")
        return parts.joined(separator: " ")
    }

    // MARK: - Private

    private static var observersInstalled = false

    private static func emit(_ reason: String, detail: String, site: String?) {
        let body = format(reason: reason, detail: detail, site: site, appActive: NSApp?.isActive ?? false,
                          caller: SyntheticInputGate.depth > 0 ? "agent-or-cli(app-control)" : "in-app",
                          keyDisplay: NSApp?.keyWindow.map(displayUUID(of:)),
                          windows: (NSApp?.windows ?? []).compactMap(info(of:)))
        WindowPlacementLog.shared.log("activation", body)
    }

    private static func info(of window: NSWindow) -> WindowInfo? {
        // Nostromo's own windows only; skips popovers/panels' content-bearing details by design.
        guard window is NostromoWindow || window is NSPanel else { return nil }
        return WindowInfo(number: window.windowNumber, displayUUID: displayUUID(of: window),
                          isVisible: window.isVisible, isKey: window.isKeyWindow,
                          occlusion: window.occlusionState.rawValue)
    }

    private static func displayUUID(of window: NSWindow) -> String {
        window.screen.flatMap { DisplayInfo.uuid(of: $0) } ?? "none"
    }
}
