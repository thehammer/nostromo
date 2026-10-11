import AppKit
import CoreGraphics

// MARK: - DisplayInfo

/// A value snapshot of one attached display, keyed by its STABLE display UUID.
///
/// `NSScreenNumber` (a `CGDirectDisplayID`) can change across reconnects and
/// re-enumerations; `CGDisplayCreateUUIDFromDisplayID` does not. Everything that
/// needs to remember "which display" (window binding, focus memory) uses `uuid`.
///
/// This is a plain struct so placement logic can be unit-tested with fake
/// displays — nothing in the logic layer needs a real `NSScreen`.
struct DisplayInfo: Equatable {
    /// Stable across reconnects. See `DisplayInfo.uuid(forDisplayID:)`.
    let uuid: String
    /// `NSScreenNumber` / `CGDirectDisplayID`. Diagnostic only — NOT an identity.
    let screenNumber: UInt32
    /// AppKit global coordinates: bottom-left origin of the MAIN display. A display
    /// stacked above main has a positive `y`; one to the left has a negative `x`.
    let frame: CGRect
    let visibleFrame: CGRect
    let backingScaleFactor: CGFloat
    let localizedName: String
    let isMain: Bool

    /// The frame a window should be placed at before entering full-screen: the
    /// target display's `visibleFrame` (inside the menu-bar band, so AppKit has
    /// no reason to constrain it onto another display).
    var placementFrame: CGRect { visibleFrame }

    /// One-line description for the placement log. No secrets, no user data.
    var logDescription: String {
        "screen#\(screenNumber) uuid=\(uuid) frame=\(DisplayInfo.fmt(frame)) visible=\(DisplayInfo.fmt(visibleFrame)) scale=\(backingScaleFactor) name=\"\(localizedName)\" main=\(isMain)"
    }

    static func fmt(_ r: CGRect) -> String {
        "(\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.size.width))x\(Int(r.size.height)))"
    }

    // MARK: Construction from AppKit

    init(uuid: String, screenNumber: UInt32, frame: CGRect, visibleFrame: CGRect,
         backingScaleFactor: CGFloat = 2, localizedName: String = "", isMain: Bool = false) {
        self.uuid = uuid
        self.screenNumber = screenNumber
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.backingScaleFactor = backingScaleFactor
        self.localizedName = localizedName
        self.isMain = isMain
    }

    init?(screen: NSScreen) {
        guard let number = DisplayInfo.screenNumber(of: screen) else { return nil }
        self.init(
            uuid: DisplayInfo.uuid(forDisplayID: number),
            screenNumber: number,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            backingScaleFactor: screen.backingScaleFactor,
            localizedName: screen.localizedName,
            isMain: screen == NSScreen.main
        )
    }

    static func screenNumber(of screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// The stable UUID string for a display id; falls back to a number-derived
    /// token only if CoreGraphics can't produce a UUID (never seen in practice).
    static func uuid(forDisplayID id: UInt32) -> String {
        if let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) {
            let cfUUID = unmanaged.takeRetainedValue()
            if let str = CFUUIDCreateString(nil, cfUUID) as String? { return str }
        }
        return "display-number-\(id)"
    }

    static func uuid(of screen: NSScreen) -> String? {
        screenNumber(of: screen).map { uuid(forDisplayID: $0) }
    }
}

// MARK: - ScreenProviding

/// The one seam between placement logic and the real display topology.
protocol ScreenProviding: AnyObject {
    /// Attached displays in `NSScreen.screens` order (main/menu-bar display first).
    var displays: [DisplayInfo] { get }
    /// `NSScreen.screensHaveSeparateSpaces` — "Displays have separate Spaces".
    /// Per-display full-screen Spaces cannot work when this is false.
    var screensHaveSeparateSpaces: Bool { get }
}

final class SystemScreenProvider: ScreenProviding {
    static let shared = SystemScreenProvider()

    var displays: [DisplayInfo] { NSScreen.screens.compactMap { DisplayInfo(screen: $0) } }
    var screensHaveSeparateSpaces: Bool { NSScreen.screensHaveSeparateSpaces }
}

// MARK: - Display-keyed focus memory

/// Persistence keys for "which focus (tab) is active on display X".
///
/// Formerly `nostromo.window{index}.activeTab` — keyed by window INDEX, which
/// silently re-pointed at a different display whenever enumeration order or the
/// set of attached displays changed. Now keyed by display UUID.
enum DisplayFocusKeys {

    static let migrationFlagKey = "nostromo.displayFocusKeysMigrated.v1"

    static func legacyKey(windowIndex: Int) -> String { "nostromo.window\(windowIndex).activeTab" }

    static func activeTabKey(displayUUID: String) -> String { "nostromo.display.\(displayUUID).activeTab" }

    /// One-time migration of the legacy per-index keys onto display UUIDs.
    ///
    /// **Mapping rule:** the legacy index `i` is the display at position `i` of
    /// `displays`, which is `NSScreen.screens` order at the time of the
    /// migration (that is how the old code assigned indices at launch).
    /// A UUID key that already exists is never overwritten. Legacy keys are left
    /// in place (harmless, and keeps a downgrade working). Runs once: guarded by
    /// `migrationFlagKey`, and only marks itself done when at least one display
    /// was available to migrate onto.
    ///
    /// - Returns: the number of keys copied.
    @discardableResult
    static func migrateLegacyKeys(onto displays: [DisplayInfo], defaults: UserDefaults = .standard) -> Int {
        guard !displays.isEmpty, !defaults.bool(forKey: migrationFlagKey) else { return 0 }
        var copied = 0
        for (index, display) in displays.enumerated() {
            let newKey = activeTabKey(displayUUID: display.uuid)
            guard defaults.string(forKey: newKey) == nil,
                  let legacy = defaults.string(forKey: legacyKey(windowIndex: index)) else { continue }
            defaults.set(legacy, forKey: newKey)
            copied += 1
        }
        defaults.set(true, forKey: migrationFlagKey)
        return copied
    }
}

// MARK: - Reconciliation (which windows to close / open)

/// Pure diff between the displays currently attached and the display UUIDs that
/// currently have a window.
enum DisplayReconciler {
    struct Plan: Equatable {
        /// UUIDs whose display is gone: their window must be closed.
        var toClose: [String]
        /// Attached displays with no window yet (new or REappeared): open one,
        /// bound to the same UUID so it recovers the remembered focus.
        var toOpen: [DisplayInfo]
    }

    static func plan(attached: [DisplayInfo], boundUUIDs: Set<String>) -> Plan {
        let attachedUUIDs = Set(attached.map(\.uuid))
        return Plan(
            toClose: boundUUIDs.subtracting(attachedUUIDs).sorted(),
            toOpen: attached.filter { !boundUUIDs.contains($0.uuid) }
        )
    }
}

// MARK: - Launch: wait for slow displays

/// Persisted count of displays seen at the last stable point, so a launch where
/// externals are still waking (fewer screens than last time) can wait briefly
/// for them instead of piling every window onto the laptop.
enum LastKnownDisplayCount {
    static let key = "nostromo.lastKnownDisplayCount"

    static func load(defaults: UserDefaults = .standard) -> Int { defaults.integer(forKey: key) }

    /// Zero is never recorded: a momentarily empty topology (lid closed, no
    /// externals) must not teach the next launch to expect nothing.
    static func record(_ count: Int, defaults: UserDefaults = .standard) {
        guard count > 0 else { return }
        defaults.set(count, forKey: key)
    }
}

/// Schedules a closure after a delay. Injected so the bounded waits are testable
/// with no wall clock.
protocol PlacementScheduler: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
}

final class MainQueueScheduler: PlacementScheduler {
    static let shared = MainQueueScheduler()
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        if delay <= 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}

/// Completes exactly once: as soon as `screenCount()` reaches `expected`, or when
/// the bounded timeout elapses, whichever comes first. Completion reports whether
/// the expected count was reached.
final class DisplayAvailabilityWaiter {
    private let expected: Int
    private let screenCount: () -> Int
    private var completion: ((_ reachedExpected: Bool) -> Void)?

    init(expected: Int, timeout: TimeInterval, scheduler: PlacementScheduler,
         screenCount: @escaping () -> Int,
         completion: @escaping (_ reachedExpected: Bool) -> Void) {
        self.expected = expected
        self.screenCount = screenCount
        self.completion = completion
        scheduler.schedule(after: timeout) { [weak self] in self?.finish() }
    }

    /// Call on every `didChangeScreenParameters` while waiting.
    func screensChanged() {
        if screenCount() >= expected { finish() }
    }

    /// True once completion has fired.
    var isFinished: Bool { completion == nil }

    private func finish() {
        guard let done = completion else { return }
        completion = nil
        done(screenCount() >= expected)
    }
}
