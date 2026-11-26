import AppKit
import SwiftUI

/// Pair a Device…: shows a one-time code and QR from the primary, then the outcome. All state is in
/// `DeviceAdminModel`. Closing the window sends `DevicePairCancel`, so the code dies with it.
final class PairDeviceWindowController: NSWindowController, NSWindowDelegate {
    private let model: DeviceAdminModel
    private let currentEvent: () -> NSEvent?

    /// `currentEvent` is the input behind a control's action; a test supplies its own.
    init(model: DeviceAdminModel, currentEvent: @escaping () -> NSEvent? = { NSApp.currentEvent }) {
        self.model = model
        self.currentEvent = currentEvent
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Pair a Device"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: PairDeviceView(
            model: model,
            gesture: { [weak self] in self?.gesture() ?? .refused(reason: .notAUserEvent) },
            close: { [weak window] in window?.close() }))
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Whether the input behind the control being pressed was a person's own, in this window.
    func gesture() -> HumanGestureVerdict {
        DeviceWindowGesture.verdict(in: window, event: currentEvent())
    }

    /// The menu pick that opened the window asks for the code: a menu item's event belongs to the menu, not to
    /// this window, so this check is the menu one. Every other check of `HumanGesture.permit` still applies.
    func beginFromMenuPick() {
        guard let window else { return }
        model.beginPairing(gesture: HumanGesture.permit(currentEvent(), control: window.contentView ?? NSView(),
                                                        menuSelection: true))
    }

    /// Open (or bring forward). The menu pick is the gesture that asks for the code.
    func present() {
        guard let window else { return }
        if !window.isVisible { beginFromMenuPick() }
        ActivationAudit.note("pair-device:menu-open")
        NSApp.activate(ignoringOtherApps: true)
        ActivationAudit.note("pair-device:menu-open-front")
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.cancelPairing() }

    func windowDidBecomeKey(_ notification: Notification) { model.windowBecameKey() }
}

struct PairDeviceView: View {
    @ObservedObject var model: DeviceAdminModel
    let gesture: () -> HumanGestureVerdict
    let close: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            content
            notice
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 360, height: 520)
        // While the server can't be reached, ask again every few seconds until it answers (a no-op otherwise).
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            model.probeWhileWaiting()
        }
    }

    @ViewBuilder private var content: some View {
        switch model.pair {
        case .idle:
            message("Make a code to pair a phone or iPad.")
            Button("Show Code") { model.beginPairing(gesture: gesture()) }
            cancelButton
        case .issuing:
            ProgressView()
            Text("Asking your Nostromo server for a code\u{2026}")
            cancelButton
        case .showing(let info):
            showing(info)
        case .paired(let name):
            Text(DeviceAdminCopy.paired(name: name)).font(.title3)
            Button("Done", action: close).keyboardShortcut(.defaultAction)
        case .expired:
            message(DeviceAdminCopy.expired)
            newCode
        case .lockedOut:
            message(DeviceAdminCopy.lockedOut)
            newCode
        case .connectionLost:
            message(DeviceAdminCopy.lostConnection)
            newCode
        case .failed:
            message(DeviceAdminCopy.saveFailed)
            newCode
        case .issueFailed:
            message(DeviceAdminCopy.issueFailed)
            newCode
        case .blocked:
            message(DeviceAdminCopy.blocked(model.adminAvailability, pairFrom: model.pairFrom))
            Button("Close", action: close)
        }
    }

    private func showing(_ info: DevicePairingInfo) -> some View {
        VStack(spacing: 12) {
            if let image = PairQR.cgImage(for: info.serverUrl) {
                Image(decorative: image, scale: 1).interpolation(.none).resizable()
                    .frame(width: 220, height: 220)
            }
            Text(serverAddress(info.serverUrl)).font(.callout).foregroundColor(.secondary)
            Text(DeviceAdminCopy.groupedCode(info.code)).font(.system(size: 34, weight: .semibold, design: .monospaced))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(DeviceAdminCopy.countdown(until: info.expiresAt, now: context.date)).foregroundColor(.secondary)
            }
            Text(DeviceAdminCopy.sharingLine).font(.footnote).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            cancelButton
        }
    }

    private var notice: some View {
        Group {
            if let text = model.gestureNotice { Text(text).font(.footnote).foregroundColor(.red) }
        }
    }

    private var cancelButton: some View {
        Button("Cancel") { model.cancelPairing(); close() }.keyboardShortcut(.cancelAction)
    }

    private var newCode: some View {
        VStack(spacing: 6) {
            Button("New Code") { model.beginPairing(gesture: gesture()) }
                .disabled(!model.canRequestNewCode)
            if !model.canRequestNewCode {
                Text(DeviceAdminCopy.waitingForServer).font(.footnote).foregroundColor(.secondary)
            }
            Button("Close", action: close)
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
    }

    /// `host:port` of the primary, from the pairing URL (never this Mac's own address).
    private func serverAddress(_ url: String) -> String {
        guard let items = URLComponents(string: url)?.queryItems else { return "" }
        let host = items.first { $0.name == "host" }?.value ?? ""
        let port = items.first { $0.name == "port" }?.value
        return port.map { "\(host):\($0)" } ?? host
    }
}
