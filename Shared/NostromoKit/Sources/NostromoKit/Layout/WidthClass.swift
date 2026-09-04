// NostromoKit — WidthClass.swift
//
// The one branch in the whole iOS presentation (W6 — ios-curated-view-
// parity, D1): compact renders one surface at a time in a single flattened
// strip (W5); regular renders the daemon's real, simultaneously-visible
// regions. There is no third value and there is no second branch — every
// renderer, every addressing behaviour, the ticker and the decision surface
// are identical in both presentations. Compact and regular differ in how
// regions are ARRANGED, and in nothing else.
//
// Nothing anywhere may branch on the device. No `UIDevice`, no
// `userInterfaceIdiom`, no `UIScreen`, no orientation notification, no size
// threshold in points, no model check — the presentation is selected by the
// app's current horizontal width class and nothing else. Both halves of the
// PRD's requirement ("an iPad in a narrow multitasking window presents the
// compact layout; a phone never presents the regular one") follow from the
// size class for free, and both break the moment anything else is consulted.
// `tests/ios_policy/test_ios_view_policy.py` names every forbidden API.
//
// import Foundation only — pure value type, exercised by `make kit-test`
// with no simulator and no device. Deliberately NOT modelled on SwiftUI's
// `UserInterfaceSizeClass`: that type does not exist on macOS, and
// NostromoKit builds for both platforms.
import Foundation

public enum WidthClass: Equatable {
    /// One surface at a time, one strip — a phone in any orientation, or an
    /// iPad in a narrow multitasking window (Slide Over, a narrow Split View).
    case compact
    /// Real regions, simultaneously visible — an iPad with room for two.
    case regular

    /// Map SwiftUI's `@Environment(\.horizontalSizeClass)`, read at exactly
    /// one place in the view tree (`DynamicFocusView`) and passed down as a
    /// value thereafter:
    ///
    ///     WidthClass.from(isRegular: horizontalSizeClass.map { $0 == .regular })
    ///
    /// `nil` — SwiftUI reporting no size class at all — means `.compact`,
    /// the same as an explicit compact class. Showing the wide layout on a
    /// surface that never claimed to be wide is the worse of the two
    /// failures: the compact presentation is correct everywhere, just
    /// smaller than it needs to be.
    ///
    /// A function rather than an inline `?? .compact` at the call site
    /// precisely so that rule is tested (`WidthClassTests`) instead of being
    /// an untested one-liner inside a view.
    public static func from(isRegular: Bool?) -> WidthClass {
        isRegular == true ? .regular : .compact
    }
}
