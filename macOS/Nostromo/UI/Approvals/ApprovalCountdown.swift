import AppKit
import NostromoKit

// AP2a: the card's `denies in 14:32` label.
//
// A 1 Hz timer rewrites the text of a label whose width is fixed, so a tick can't
// change the card's layout: the string changes, nothing else does. There is no
// animation (under Reduce Motion or not). The timer stops when the card leaves its
// window and when this object goes away, so a gone card leaves nothing ticking.
//
// `NostromoKit.ApprovalCountdown` does the arithmetic and the formatting.

final class ApprovalCountdownLabel {

    /// Wide enough for `denies in 60:00` in the label font; never changes. The card gives the label this width.
    static let width: CGFloat = 108

    let label: NSTextField

    private let deadlineAtMs: UInt64
    private let nowMs: () -> UInt64
    private var timer: Timer?

    var isRunning: Bool { timer != nil }
    private(set) var secondsLeft: Int

    init(deadlineAtMs: UInt64,
         nowMs: @escaping () -> UInt64 = { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }) {
        self.deadlineAtMs = deadlineAtMs
        self.nowMs = nowMs
        secondsLeft = ApprovalCountdown.secondsLeft(deadlineAtMs: deadlineAtMs, nowMs: nowMs())

        label = NSTextField(labelWithString: ApprovalCountdown.label(seconds: secondsLeft))
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = Theme.fgMuted
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.setAccessibilityElement(false)   // a ticking value is noise; the card's announcement carries the deadline
    }

    deinit { timer?.invalidate() }

    /// Show the current time and start ticking once a second. Starting twice is a no-op.
    func start() {
        tick()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Update the text from the clock. Only the string changes.
    func tick() {
        secondsLeft = ApprovalCountdown.secondsLeft(deadlineAtMs: deadlineAtMs, nowMs: nowMs())
        let text = ApprovalCountdown.label(seconds: secondsLeft)
        if label.stringValue != text { label.stringValue = text }
    }
}
