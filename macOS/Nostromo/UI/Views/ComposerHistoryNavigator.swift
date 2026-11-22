import Foundation

/// What the composer's Up handler tells a "before history" step (the seam S2 uses to try taking back a
/// queued message first).
struct ComposerUpContext: Equatable {
    var text: String
    var hasDraftImages: Bool
}

/// What a key press asks of the composer's text, as the composer sees it.
struct ComposerKeyContext: Equatable {
    var text: String
    /// UTF-16 offset of the caret (the selection's start).
    var caret: Int
    var selectionLength: Int
    var hasMarkedText: Bool
    /// Any of ⌘ ⌥ ⌃ ⇧ held.
    var hasModifiers: Bool
    /// `HumanGesture` said a person pressed it.
    var isHuman: Bool
    var hasDraftImages: Bool
}

enum ComposerHistoryOutcome: Equatable {
    /// Not ours: AppKit moves the caret as usual.
    case passThrough
    /// Handled with no change to the text (the "before history" step acted).
    case handled
    /// Replace the composer's text (caret at its end) and announce `announcement`.
    case show(text: String, announcement: String)
}

/// One composer's (one window's) walk through its focus's history, like a shell's Up and Down. Pure:
/// no AppKit, so every key rule is a unit test. The store is shared; this state is per composer.
///
/// - Navigation starts with the first recall and saves the draft as it was. It walks a snapshot of the
///   history taken then, so an entry another window sends meanwhile does not shift it.
/// - Edits to a recalled entry are kept for that entry for the rest of the navigation (readline). The
///   stored entries are never changed.
/// - `end()` (a send, a focus change, a clear) forgets all of it.
///
/// Up and Down act only for an untouched, human key press: no modifier, no marked text (an IME candidate
/// list owns the arrows), no selection.
///
/// Caret rule: Up acts with the caret at the very start (an empty composer counts). While navigating, a
/// one-line text with the caret at either end also acts, so one Up per entry walks single-line history; a
/// multi-line one lets AppKit move the caret first. Down acts only while navigating, with the caret at the end.
final class ComposerHistoryNavigator {

    /// A step that runs before history on Up, only when navigation has not started. Returns true when it
    /// acted, so Up recalls nothing. Nil in this slice; the queue slice (S2) sets it to take back the
    /// newest queued message when the composer is empty.
    var upInterceptor: ((ComposerUpContext) -> Bool)?

    /// Newest first.
    private let entries: () -> [String]

    init(entries: @escaping () -> [String]) {
        self.entries = entries
    }

    var isNavigating: Bool { index != nil }

    func up(_ key: ComposerKeyContext) -> ComposerHistoryOutcome {
        guard acts(key) else { return .passThrough }
        let atStart = key.caret == 0
        let atEnd = key.caret == key.text.utf16.count
        if let current = index {
            let singleLine = !key.text.contains(where: \.isNewline)
            guard atStart || (singleLine && atEnd) else { return .passThrough }
            guard current + 1 < snapshot.count else { return .passThrough }   // already the oldest
            return move(to: current + 1, leaving: current, shown: key.text)
        }
        guard atStart else { return .passThrough }
        if upInterceptor?(ComposerUpContext(text: key.text, hasDraftImages: key.hasDraftImages)) == true {
            return .handled
        }
        let all = entries()
        guard !all.isEmpty else { return .passThrough }
        snapshot = all
        draft = key.text
        edits = [:]
        return move(to: 0, leaving: nil, shown: key.text)
    }

    func down(_ key: ComposerKeyContext) -> ComposerHistoryOutcome {
        guard acts(key), let current = index, key.caret == key.text.utf16.count else { return .passThrough }
        if current > 0 { return move(to: current - 1, leaving: current, shown: key.text) }
        // Past the newest: the draft, exactly as it was.
        let restored = draft
        end()
        return .show(text: restored, announcement: "Draft restored")
    }

    /// A send, a focus change, or a clear.
    func end() {
        index = nil
        snapshot = []
        draft = ""
        edits = [:]
    }

    /// "History N of M" for where the walk stands; nil when not navigating.
    var position: (number: Int, total: Int)? {
        index.map { ($0 + 1, snapshot.count) }
    }

    // MARK: Private

    private var index: Int?
    private var snapshot: [String] = []
    private var draft = ""
    /// What the user changed in a visited entry, by its index.
    private var edits: [Int: String] = [:]

    private func acts(_ key: ComposerKeyContext) -> Bool {
        key.isHuman && !key.hasModifiers && !key.hasMarkedText && key.selectionLength == 0
    }

    private func move(to new: Int, leaving old: Int?, shown: String) -> ComposerHistoryOutcome {
        if let old { edits[old] = shown == snapshot[old] ? nil : shown }
        index = new
        return .show(text: edits[new] ?? snapshot[new],
                     announcement: "History \(new + 1) of \(snapshot.count)")
    }
}
