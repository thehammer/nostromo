import Foundation

/// A button on a toast: `title` is its label, `handler` runs when it is clicked (the toast then
/// dismisses). Clicking anywhere else on the toast dismisses it without running the handler.
struct ToastAction {
    let title: String
    let handler: () -> Void
}
