import AppKit
import SwiftUI

/// The gesture check of the device windows' own controls. The event a control acts on must belong to the
/// control's window: a SwiftUI `.alert`, `.sheet` or popover is a window of its own, and a click there is
/// refused as "not a user event", so a confirmation shown that way never acts. Confirm inside the window.
enum DeviceWindowGesture {
    static func verdict(in window: NSWindow?, event: NSEvent?) -> HumanGestureVerdict {
        guard let view = window?.contentView else { return .refused(reason: .notAUserEvent) }
        return HumanGesture.permit(event, control: view)
    }
}

/// Devices…: the paired phones and iPads, with Revoke… and the revoked ones below.
final class DevicesWindowController: NSWindowController {
    private let model: DeviceAdminModel
    private let currentEvent: () -> NSEvent?

    /// `currentEvent` is the input behind a control's action; a test supplies its own.
    init(model: DeviceAdminModel, currentEvent: @escaping () -> NSEvent? = { NSApp.currentEvent }) {
        self.model = model
        self.currentEvent = currentEvent
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Devices"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: DevicesView(model: model, gesture: { [weak self] in
            self?.gesture() ?? .refused(reason: .notAUserEvent)
        }))
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Whether the input behind the control being pressed was a person's own, in this window.
    func gesture() -> HumanGestureVerdict {
        DeviceWindowGesture.verdict(in: window, event: currentEvent())
    }

    func present() {
        model.requestList()
        ActivationAudit.note("devices:menu-open")
        NSApp.activate(ignoringOtherApps: true)
        ActivationAudit.note("devices:menu-open-front")
        window?.makeKeyAndOrderFront(nil)
    }
}

struct DevicesView: View {
    @ObservedObject var model: DeviceAdminModel
    let gesture: () -> HumanGestureVerdict
    /// The device whose Revoke… was pressed: its row shows the confirmation (inside this window).
    @State private var pendingRevoke: String?

    private var banner: String? {
        switch model.adminAvailability {
        case .serverUnreachable, .daemonNotRunning: return DeviceAdminCopy.unreachableList
        case .readOnly: return DeviceAdminCopy.readOnly
        case .off: return DeviceAdminCopy.off
        case .available, .revokeOnly: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let banner { Text(banner).foregroundColor(.secondary) }
            if model.adminAvailability == .serverUnreachable || model.adminAvailability == .daemonNotRunning,
               model.hasList {
                Text("Showing the last list received. It may be out of date.").font(.footnote).foregroundColor(.secondary)
            }
            if let notice = model.gestureNotice { Text(notice).font(.footnote).foregroundColor(.red) }
            if model.adminAvailability == .off {
                Spacer()
            } else {
                list
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 320)
    }

    /// The Revoke confirmation, a row of this window (not an alert: see `DeviceWindowGesture`). Its Revoke
    /// button is the control the gesture check runs on.
    private func confirmation(for device: DeviceSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DeviceAdminCopy.revokeConfirmation(name: device.name)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Revoke") {
                    let verdict = gesture()
                    pendingRevoke = nil
                    model.revoke(deviceId: device.id, gesture: verdict)
                }
                Button("Cancel") { pendingRevoke = nil }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private var list: some View {
        List {
            Section("Paired") {
                if model.activeDevices.isEmpty { Text("No devices are paired.").foregroundColor(.secondary) }
                ForEach(model.activeDevices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.headline)
                            Text("\(device.kind.capitalized) \u{00B7} Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.subheadline).foregroundColor(.secondary)
                            Text(DeviceAdminCopy.lastSeen(device)).font(.subheadline).foregroundColor(.secondary)
                            if let status = model.revokeStatus[device.id] {
                                Text(status).font(.subheadline)
                            }
                        }
                        Spacer()
                        Button("Revoke\u{2026}") { pendingRevoke = device.id }
                            .disabled(!model.canRevoke || pendingRevoke == device.id)
                    }
                    if pendingRevoke == device.id { confirmation(for: device) }
                }
            }
            if !model.revokedDevices.isEmpty {
                Section("Revoked") {
                    ForEach(model.revokedDevices) { device in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(model.revokeStatus[device.id] ?? DeviceAdminCopy.revokedLabel(device))
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
}
