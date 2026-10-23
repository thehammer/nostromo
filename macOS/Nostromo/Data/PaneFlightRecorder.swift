import Foundation

/// A bounded, content-free flight recorder for one transcript pane.
///
/// The question it answers: "the pane went blank and redrew; what did the pane do in the seconds
/// before?" It keeps the last `capacity` structural events (views materialized or evicted, the
/// document height, the scroll offset, layout, window and app state...) in a ring that is written
/// on the main thread, in O(1), without allocating: the storage is one preallocated array of plain
/// value structs and an event is four doubles, an enum and a counter.
///
/// **Structure only, never content.** An event carries a kind, a reason, four numbers and a
/// timestamp. There is no string slot, so no turn text, title, tool argument or path can be recorded
/// even by mistake. Keep it that way: a new payload is a number, a flag (0/1) or a case of `Kind` or
/// `Reason`.
final class PaneFlightRecorder {

    static let defaultCapacity = 200

    /// What happened. `name` is the JSON `kind`; `fieldNames` labels the numeric slots `a ... d`.
    enum Kind: UInt8, CaseIterable {
        /// Turn views were built: a = how many, b = views now, c = turns retained.
        case viewsMaterialized
        /// Turn views were dropped: a = how many, b = views now, c = turns retained (reason says why).
        case viewsEvicted
        /// The materialization window changed: a = first turn index, b = last, c = viewport top, d = viewport bottom.
        case windowChange
        /// The document view's height changed: a = old frame height, b = new, c = estimated (virtualizer) height.
        case docHeight
        /// The clip view scrolled (coalesced): a = offset y, b = document height, c = viewport height.
        case scroll
        /// The pane's size changed: a = width, b = height, c = scroll view height, d = content width.
        case layout
        /// The session's transcript was cleared: a = turns retained before, b = clears so far.
        case transcriptClear
        /// One measurement blew its budget: a = milliseconds, b = turn index.
        case measureStall
        /// The window became (1) or resigned (0) key.
        case windowKey
        /// The window changed screen: a = screen width, b = screen height, c = backing scale.
        case windowScreen
        /// The window's occlusion changed: a = 1 when visible.
        case windowOcclusion
        /// The app became (1) or resigned (0) active.
        case appActive
        /// The system is going to sleep.
        case systemSleep
        /// The system woke.
        case systemWake
        /// The display configuration changed: a = number of screens.
        case displayReconfig
        /// A visibility-relevant property of the pane changed: a = pane alpha, b = pane hidden,
        /// c = scroll view hidden, d = scroll view is still a subview of the pane (1) or not (0).
        case paneState
        /// The pane moved into (1) or out of (0) a window.
        case moveToWindow
        /// A draw heartbeat (coalesced): a = visible rect width, b = height, c = turn rows in it, d = rows painted.
        case draw
        /// The detector fired: a = rule (see `PaneRenderWatch`), b = severity.
        case detectorHit
        /// A capture file was written.
        case capture

        var name: String { String(describing: self) }

        var fieldNames: [String] {
            switch self {
            case .viewsMaterialized: return ["added", "views", "turns"]
            case .viewsEvicted:      return ["removed", "views", "turns"]
            case .windowChange:      return ["first", "last", "viewportTop", "viewportBottom"]
            case .docHeight:         return ["oldHeight", "newHeight", "estimatedHeight"]
            case .scroll:            return ["offsetY", "documentHeight", "viewportHeight"]
            case .layout:            return ["width", "height", "scrollViewHeight", "contentWidth"]
            case .transcriptClear:   return ["turnsBefore", "clears"]
            case .measureStall:      return ["ms", "turnIndex"]
            case .windowKey:         return ["isKey"]
            case .windowScreen:      return ["screenWidth", "screenHeight", "scale"]
            case .windowOcclusion:   return ["visible"]
            case .appActive:         return ["active"]
            case .systemSleep:       return []
            case .systemWake:        return []
            case .displayReconfig:   return ["screens"]
            case .paneState:         return ["alpha", "paneHidden", "scrollViewHidden", "scrollViewAttached"]
            case .moveToWindow:      return ["inWindow"]
            case .draw:              return ["visibleWidth", "visibleHeight", "rowsInVisibleRect", "rowsPainted"]
            case .detectorHit:       return ["rule", "severity"]
            case .capture:           return ["manual"]
            }
        }
    }

    /// Why a structural event happened, where the cause is known.
    enum Reason: UInt8 {
        case none, scroll, resize, clear, splice, shed, fold, manual, test

        var name: String { String(describing: self) }
    }

    struct Event {
        let seq: UInt64
        let uptimeNs: UInt64
        let kind: Kind
        let reason: Reason
        let a: Double
        let b: Double
        let c: Double
        let d: Double
        /// How many occurrences this event stands for (1 unless coalesced).
        let coalescedCount: Int
    }

    let capacity: Int
    private(set) var count = 0
    private(set) var totalRecorded: UInt64 = 0

    /// Preallocated; `head` is the slot the next event takes.
    private var slots: [Event]
    private var head = 0
    /// The newest event of each kind: its sequence number and when it was recorded, for coalescing.
    private var lastSeqByKind = [UInt64](repeating: 0, count: Kind.allCases.count)
    private var lastNsByKind = [UInt64](repeating: 0, count: Kind.allCases.count)

    init(capacity: Int = PaneFlightRecorder.defaultCapacity) {
        self.capacity = max(1, capacity)
        let blank = Event(seq: 0, uptimeNs: 0, kind: .capture, reason: .none, a: 0, b: 0, c: 0, d: 0, coalescedCount: 1)
        slots = [Event](repeating: blank, count: self.capacity)
    }

    // MARK: - Recording

    func record(_ kind: Kind, reason: Reason = .none,
                _ a: Double = 0, _ b: Double = 0, _ c: Double = 0, _ d: Double = 0) {
        append(kind, reason: reason, a, b, c, d, ns: Self.nowNs())
    }

    /// Like `record`, but a second event of the same kind inside `minIntervalMs` of the newest one
    /// replaces its payload and counts itself in it instead of taking a slot: a scroll or a draw
    /// storm is one line saying "this happened N times, last with these numbers".
    func recordCoalesced(_ kind: Kind, minIntervalMs: Double, reason: Reason = .none,
                         _ a: Double = 0, _ b: Double = 0, _ c: Double = 0, _ d: Double = 0) {
        let ns = Self.nowNs()
        let k = Int(kind.rawValue)
        let lastSeq = lastSeqByKind[k]
        if lastSeq != 0, Double(ns &- lastNsByKind[k]) / 1_000_000 < minIntervalMs {
            // The newest event of this kind is still in the ring unless enough later events pushed it out.
            let newestSeq = totalRecorded
            if newestSeq - lastSeq < UInt64(capacity) {
                let slot = (head - 1 - Int(newestSeq - lastSeq) + 2 * capacity) % capacity
                let old = slots[slot]
                if old.seq == lastSeq {
                    slots[slot] = Event(seq: old.seq, uptimeNs: old.uptimeNs, kind: kind, reason: reason,
                                        a: a, b: b, c: c, d: d, coalescedCount: old.coalescedCount + 1)
                    return
                }
            }
        }
        append(kind, reason: reason, a, b, c, d, ns: ns)
    }

    private func append(_ kind: Kind, reason: Reason, _ a: Double, _ b: Double, _ c: Double, _ d: Double, ns: UInt64) {
        totalRecorded += 1
        slots[head] = Event(seq: totalRecorded, uptimeNs: ns, kind: kind, reason: reason,
                            a: a, b: b, c: c, d: d, coalescedCount: 1)
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
        let k = Int(kind.rawValue)
        lastSeqByKind[k] = totalRecorded
        lastNsByKind[k] = ns
    }

    // MARK: - Reading (capture time only; allocates)

    /// Oldest to newest.
    var events: [Event] {
        guard count > 0 else { return [] }
        let first = count < capacity ? 0 : head
        return (0 ..< count).map { slots[(first + $0) % capacity] }
    }

    /// The ring as JSON-ready dictionaries, oldest first. `now` anchors the UTC times.
    func eventDictionaries(now: Date) -> [[String: Any]] {
        let nowNs = Self.nowNs()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return events.map { event in
            let ageSeconds = Double(Int64(bitPattern: nowNs &- event.uptimeNs)) / 1_000_000_000
            var out: [String: Any] = [
                "seq": event.seq,
                "kind": event.kind.name,
                "tMs": Double(event.uptimeNs) / 1_000_000,
                "wall": formatter.string(from: now.addingTimeInterval(-ageSeconds)),
            ]
            if event.reason != .none { out["reason"] = event.reason.name }
            let values = [event.a, event.b, event.c, event.d]
            for (i, name) in event.kind.fieldNames.enumerated() {
                out[name] = values[i].isFinite ? values[i] : -1
            }
            if event.coalescedCount > 1 { out["n"] = event.coalescedCount }
            return out
        }
    }

    // MARK: - Clock

    private static func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
}
