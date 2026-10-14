import Foundation

/// How a focus (one agent pane's session tag) shows activity (design contract D1).
public enum TranscriptViewMode: String, Codable, Sendable, Equatable, CaseIterable {
    /// Activity rows and tool groups start folded.
    case focus
    /// Every activity row and tool group starts open.
    case allActivity
}

/// Whether a foldable starts open (contract §2.2). Pure: the store feeds it, a view applies it.
public enum FocusFoldResolver {

    public enum Foldable: Equatable, Sendable {
        /// An activity row. It never auto-opens: `auto` and `derivedStuck` are ignored.
        case activityRow
        /// A TF2 tool group.
        case toolGroup
    }

    /// First match wins:
    /// 1. `explicit`, when the user chose;
    /// 2. (groups only) `auto == true`, or `derivedStuck`;
    /// 3. the mode: `allActivity` opens, `focus` closes.
    public static func isOpen(_ foldable: Foldable, mode: TranscriptViewMode, explicit: Bool?,
                              auto: Bool?, derivedStuck: Bool) -> Bool {
        if let explicit { return explicit }
        if foldable == .toolGroup, auto == true || derivedStuck { return true }
        return mode == .allActivity
    }

    /// A result fold: the explicit choice, else open when the call failed (TF4, unchanged).
    public static func resultOpen(explicit: Bool?, isError: Bool) -> Bool {
        explicit ?? isError
    }
}
