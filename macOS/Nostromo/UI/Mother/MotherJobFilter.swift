import Foundation
import NostromoKit

/// What the Mother list's `From:` control can be set to.
enum MotherOriginSelection: Hashable {
    case all
    case focus(tag: String)
    case unverified(tag: String)
    case you
    case unknown
}

/// One entry in the `From:` pop-up.
struct MotherOriginFilterEntry: Equatable {
    let selection: MotherOriginSelection
    /// Sanitised and capped; what the menu and the header show.
    let title: String
    /// Jobs that match this entry.
    let count: Int
}

struct MotherJobFilterResult: Equatable {
    /// Matching jobs, grouped by state.
    let groups: [MotherJobGroup]
    let matched: Int
    let total: Int
    /// In order: All; open focuses A-Z; closed focuses; unverified claims; You; Unknown.
    /// An entry appears only if a job matches it, except the selected one.
    let entries: [MotherOriginFilterEntry]
    /// The selected entry's name, for the header and the empty message.
    let selectionTitle: String
}

/// Pure: jobs, the daemon's annotations and a selection in; the grouped, filtered jobs and the
/// pop-up entries out. No view state, no store access.
enum MotherJobFilter {

    static func selection(for annotation: MotherJobAnnotation?) -> MotherOriginSelection {
        guard let origin = annotation?.origin else { return .unknown }
        switch origin.kind {
        case .focus:
            guard let tag = origin.focusTag else { return .unknown }
            return .focus(tag: tag)
        case .unverified: return .unverified(tag: origin.focusTag ?? "")
        case .you:        return .you
        case .unknown, .other: return .unknown
        }
    }

    static func apply(
        jobs: [MotherJob],
        annotations: [String: MotherJobAnnotation],
        selection: MotherOriginSelection,
        currentName: (String) -> String?
    ) -> MotherJobFilterResult {
        // One pass: each job's class, a representative display per class, and counts.
        var counts: [MotherOriginSelection: Int] = [:]
        var display: [MotherOriginSelection: MotherOriginDisplay] = [:]
        var classOf: [String: MotherOriginSelection] = [:]
        for job in jobs {
            let note = annotations[job.id]
            let cls = Self.selection(for: note)
            classOf[job.id] = cls
            counts[cls, default: 0] += 1
            if display[cls] == nil { display[cls] = MotherOriginDisplay.make(annotation: note, currentName: currentName) }
        }

        let matching = selection == .all ? jobs : jobs.filter { classOf[$0.id] == selection }

        func title(_ s: MotherOriginSelection) -> String {
            if let d = display[s] { return s == .you ? "You" : d.text }
            switch s {
            case .all:               return "All"
            case .you:               return "You"
            case .unknown:           return "Unknown origin"
            case .focus(let tag):
                let name = MotherOriginDisplay.clean(currentName(tag), cap: MotherOriginDisplay.rowCap)
                if !name.isEmpty { return name }
                return "\(fallback(tag)) (closed)"
            case .unverified(let tag): return "\(fallback(tag))?"
            }
        }
        func entry(_ s: MotherOriginSelection) -> MotherOriginFilterEntry {
            MotherOriginFilterEntry(selection: s, title: s == .unknown ? "Unknown origin" : title(s), count: counts[s] ?? 0)
        }

        var focuses: [(Bool, MotherOriginFilterEntry)] = []   // (isClosed, entry)
        var unverified: [MotherOriginFilterEntry] = []
        var present = Set(counts.keys)
        present.insert(selection)
        for s in present {
            switch s {
            case .focus(let tag): focuses.append((currentName(tag) == nil, entry(s)))
            case .unverified:     unverified.append(entry(s))
            default: break
            }
        }
        func byTitle(_ a: MotherOriginFilterEntry, _ b: MotherOriginFilterEntry) -> Bool {
            let c = a.title.localizedCaseInsensitiveCompare(b.title)
            return c == .orderedSame ? "\(a.selection)" < "\(b.selection)" : c == .orderedAscending
        }
        var entries = [MotherOriginFilterEntry(selection: .all, title: "All", count: jobs.count)]
        entries += focuses.filter { !$0.0 }.map(\.1).sorted(by: byTitle)
        entries += focuses.filter { $0.0 }.map(\.1).sorted(by: byTitle)
        entries += unverified.sorted(by: byTitle)
        for s in [MotherOriginSelection.you, .unknown] where present.contains(s) { entries.append(entry(s)) }

        return MotherJobFilterResult(
            groups: MotherJobGrouping.groups(from: matching),
            matched: matching.count,
            total: jobs.count,
            entries: entries,
            selectionTitle: selection == .all ? "All" : entry(selection).title)
    }

    private static func fallback(_ tag: String) -> String {
        let s = MotherOriginDisplay.clean(tag, cap: MotherOriginDisplay.rowCap)
        return s.isEmpty ? "focus" : s
    }
}
