import Foundation
import NostromoKit

/// Pure text, label and state functions for the model chip and popup: everything the
/// views show, with no AppKit in it, so the exact PRD copy can be unit-tested.
///
/// (Skeleton: filled in by the implementation step of M2.)
enum ModelPresentation {

    enum ChipStyle: Equatable {
        /// A model the session itself reported, or one somebody chose.
        case normal
        /// Dimmed: not yet fact (a start-on model nobody chose, a switch in flight).
        case pending
    }

    /// What the chip shows.
    struct Chip: Equatable {
        var title: String
        var tooltip: String
        var accessibilityLabel: String
        var accessibilityHint: String
        var style: ChipStyle
        var isEnabled: Bool
    }

    struct ModelRow: Equatable {
        /// The alias a selection asks for (`"opus"`).
        var alias: String
        var title: String
        /// The full model name the alias currently resolves to.
        var secondary: String
        var isCurrent: Bool
        var accessibilityLabel: String
        var tooltip: String?
    }

    struct EffortRow: Equatable {
        /// `"default"` or an explicit level, as sent on the wire.
        var value: String
        var title: String
        var isCurrent: Bool
        var isEnabled: Bool
        /// Why the row is disabled.
        var tooltip: String?
        var accessibilityLabel: String
    }

    static let staleCatalogNotice = "Model list may be out of date"
    static let disconnectedTooltip = "Not connected to nostromd"

    static func chip(state: SessionModelStateWire?, isConnected: Bool) -> Chip? { nil }

    static func familyName(forModel model: String) -> String { "" }

    static func modelRows(state: SessionModelStateWire?, catalog: ModelCatalogState?) -> [ModelRow] { [] }

    static func effortRows(state: SessionModelStateWire?, catalog: ModelCatalogState?) -> [EffortRow] { [] }

    static func footerTitle(agent: String) -> String { "" }
}
