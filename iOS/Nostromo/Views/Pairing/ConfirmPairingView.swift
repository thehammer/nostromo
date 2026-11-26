// Nostromo iOS — ConfirmPairingView.swift
//
// Shown only after a successful `PairCheck` (D4). The name is editable; the D6 line says what
// pairing will do to this device's current pairing. Nothing here mentions mail, calendar or todos.

import SwiftUI
import NostromoKit

struct ConfirmPairingView: View {
    @ObservedObject var model: PairingFlowModel
    let confirmation: PairingConfirmation
    let kindName: String
    let isPairing: Bool

    var body: some View {
        Form {
            switch confirmation.existing {
            case .none:
                EmptyView()
            case .sameServer:
                Section { Text(PairingCopy.replacesPairing(kind: kindName)) }
            case .differentServer(let oldAddress, _):
                Section {
                    Label(PairingCopy.differentServer(kind: kindName, old: oldAddress, new: confirmation.address),
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text(PairingCopy.confirmation(kind: kindName, address: confirmation.address))
                    .font(.headline)
                LabeledContent("Address", value: confirmation.address)
                LabeledContent("Port", value: String(confirmation.port))
                LabeledContent("Code", value: confirmation.code)
                TextField("Name", text: $model.name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            } header: {
                Text("Name")
            }
            Section {
                Button {
                    Task { await model.confirm() }
                } label: {
                    HStack {
                        Text("Pair").frame(maxWidth: .infinity)
                        if isPairing { ProgressView() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isPairing)
            }
        }
        .navigationTitle(PairingCopy.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
