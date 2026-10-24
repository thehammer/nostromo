import Foundation
import Combine
import NostromoKit

/// Every focus's tracker board and summary, fed by `AppStore` (T1). One instance per app
/// (`shared`), so every window's tracker pane for a focus reads the same board from the same
/// delivery.
///
/// `changes` publishes a focus tag when that focus's board or summary changed. It is coalesced to at
/// most 10 deliveries a second per tag: the first change goes out at once, later ones within the
/// window are folded into one delivery at the end of it, which always carries the latest state.
/// A subscriber reads `board(for:)` when it hears its tag.
///
/// Summaries are announced only when they change; boards on every frame (see `ingest`).
///
/// A dropped daemon connection keeps every board (the pane never blanks); the reconnect's replayed
/// board replaces it. `forget(tag:)` drops a removed focus.
final class TrackerStore {
    static let shared = TrackerStore()

    /// The shortest gap between two deliveries for one tag (10 Hz).
    static let minimumInterval: TimeInterval = 0.1

    let changes = PassthroughSubject<String, Never>()

    private(set) var boards: [String: TrackerBoardViewWire] = [:]
    private(set) var summaries: [String: TrackerSummaryFrameWire] = [:]

    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var lastDelivery: [String: Date] = [:]
    private var pending: Set<String> = []

    /// `schedule` runs work after a delay on the main thread (tests pass a manual scheduler).
    init(now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.now = now
        self.schedule = schedule
    }

    func board(for tag: String) -> TrackerBoardViewWire? {
        boards[tag]
    }

    func summary(for tag: String) -> TrackerSummaryFrameWire? {
        summaries[tag]
    }

    /// Take one decoded daemon frame; frames that are not tracker frames are ignored.
    func ingest(_ msg: ServerMsg) {
        switch msg {
        case .trackerBoard(let frame):
            // `board: null` means the focus has no tracker now. The pane only exists while the
            // tree has a tracker leaf, and it never blanks, so the last board stays. An identical
            // board is still announced: the pane's diff turns it into no change at all, which is
            // what its render probe reports (PRD criterion 20).
            guard let board = frame.board else { return }
            boards[frame.tag] = board
            noteChange(frame.tag)
        case .trackerSummary(let summary):
            guard summaries[summary.tag] != summary else { return }
            summaries[summary.tag] = summary
            noteChange(summary.tag)
        default:
            break
        }
    }

    /// The daemon connection dropped. Boards stay as they were: no placeholder, no `Loading`, so
    /// there is nothing to do; the reconnect's replayed board replaces them.
    func daemonDisconnected() {}

    /// The focus is gone.
    func forget(tag: String) {
        boards.removeValue(forKey: tag)
        summaries.removeValue(forKey: tag)
        lastDelivery.removeValue(forKey: tag)
        pending.remove(tag)
    }

    // MARK: - Coalescing

    private func noteChange(_ tag: String) {
        guard !pending.contains(tag) else { return }   // a delivery is already due; it reads the latest
        let elapsed = lastDelivery[tag].map { now().timeIntervalSince($0) } ?? .infinity
        if elapsed >= Self.minimumInterval {
            deliver(tag)
        } else {
            pending.insert(tag)
            schedule(Self.minimumInterval - elapsed) { [weak self] in
                guard let self, self.pending.remove(tag) != nil else { return }
                self.deliver(tag)
            }
        }
    }

    private func deliver(_ tag: String) {
        lastDelivery[tag] = now()
        changes.send(tag)
    }
}
