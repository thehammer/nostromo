import Foundation

/// How a daemon-driven decision request was resolved.
enum DecisionAnswerRecord: Equatable {
    /// The operator chose this option's id.
    case choice(String)
    /// The operator dismissed the modal without choosing.
    case dismissed
}

/// Tracks resolved decision-modal answers, held **outside** any sheet or view —
/// the same discipline `TurnInteractionStore` documents for `AskQuestionView`.
///
/// `DecisionSheet` is a transient, presented-once `NSWindowController`, not a
/// virtualized transcript row, so it doesn't get torn down and rebuilt on
/// scroll the way a turn card does. But the failure mode `TurnInteractionStore`
/// exists to prevent — a reconstructed view starting from a blank slate and
/// sending a second answer into a live session — is exactly what a *second*
/// presentation of a sheet for the same `request_id` would risk, whether that
/// happens because of a duplicate broadcast, a future app-relaunch replay path,
/// or a maintenance change that adds a second construction site. So the same
/// fix applies: nothing about "has this request already been resolved" may
/// live only inside the sheet.
///
/// Bounded on purpose. `forget(requestId:)` is called once a request's sheet
/// has closed and the answer has been sent — decisions are rare, operator-paced
/// events, not a firehose, so this does not grow across a long session the way
/// an unbounded log would; the discipline is still worth stating explicitly so
/// nobody "fixes" a future leak by making this permanent.
final class DecisionStore {

    /// App-wide instance. Decision answers must be visible from whichever
    /// `MainLayout` (window) happens to receive the next broadcast for the
    /// same request, so this is a singleton like `AppStore.shared` and
    /// `FocusStore.shared` rather than one instance per window.
    static let shared = DecisionStore()

    private var records: [String: DecisionAnswerRecord] = [:]

    /// Record how `requestId` was resolved. Callers must call this **before**
    /// sending the answer onward to the daemon — mirroring `ReplView`'s
    /// "record before sending" rule: if the send path is ever torn down
    /// mid-flight, the fact that this request is done is already outside any
    /// view or in-flight call.
    func recordAnswer(requestId: String, record: DecisionAnswerRecord) {
        records[requestId] = record
    }

    /// Whether `requestId` has already been resolved, however it was resolved.
    func isResolved(requestId: String) -> Bool {
        records[requestId] != nil
    }

    /// The chosen option's id, if `requestId` was resolved with a choice.
    /// `nil` for an unresolved request **and** for one resolved by dismissal —
    /// there is no chosen option to render as chosen in either case.
    func answeredChoiceId(for requestId: String) -> String? {
        if case .choice(let id) = records[requestId] { return id }
        return nil
    }

    /// Forget a request once its sheet has closed and its answer has been
    /// sent. Keeps this store from growing without bound.
    func forget(requestId: String) {
        records.removeValue(forKey: requestId)
    }

    /// Currently-tracked (not yet forgotten) request ids. For tests and diagnostics.
    var trackedRequestCount: Int { records.count }
}
