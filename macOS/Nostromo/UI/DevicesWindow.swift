import AppKit
import SwiftUI

/// Devices…: the paired phones and iPads, with Revoke… and the revoked ones below.
final class DevicesWindowController: NSWindowController {
    private let model: DeviceAdminModel

    init(model: DeviceAdminModel) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Devices"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: DevicesView(model: model, gesture: { [weak window] in
            guard let view = window?.contentView else { return .refused(reason: .notAUserEvent) }
            return HumanGesture.permit(NSApp.currentEvent, control: view)
        }))
        window.center()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func present() {
        model.requestList()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct DevicesView: View {
    @ObservedObject var model: DeviceAdminModel
    let gesture: () -> HumanGestureVerdict
    @State private var pendingRevoke: DeviceSummary?

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
            if model.adminAvailability == .off {
                Spacer()
            } else {
                list
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 320)
        .alert(item: $pendingRevoke) { device in
            Alert(title: Text(DeviceAdminCopy.revokeConfirmation(name: device.name)),
                  primaryButton: .destructive(Text("Revoke")) { model.revoke(deviceId: device.id, gesture: gesture()) },
                  secondaryButton: .cancel())
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
                        Button("Revoke\u{2026}") { pendingRevoke = device }.disabled(!model.canRevoke)
                    }
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
