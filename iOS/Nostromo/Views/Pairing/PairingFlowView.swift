// Nostromo iOS — PairingFlowView.swift
//
// The container for first launch and re-pairing: the start screen, the scanner or typed entry, the
// check, the confirmation, and the failure states. The rules live in `PairingFlowModel` (Kit); this
// view only renders its steps.

import SwiftUI
import NostromoKit

struct PairingFlowView: View {
    @EnvironmentObject private var session: AppSession
    @StateObject private var model: PairingFlowModel

    private let initialLink: PairLink?
    private let onCancel: (() -> Void)?

    private enum Screen { case start, scanner, entry }
    @State private var screen: Screen = .start
    @State private var address: String
    @State private var code: String

    /// `link` applies an address and code straight to the check (a scanned QR or a system-Camera
    /// link). `canCancel` is true when this is shown over a paired app.
    init(session: AppSession, link: PairLink? = nil, prefillAddress: String? = nil, onCancel: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: session.makePairingModel())
        initialLink = link
        self.onCancel = onCancel
        _address = State(initialValue: link?.host ?? prefillAddress ?? ConnectionSettings.lastAddress ?? "")
        _code = State(initialValue: link?.code ?? "")
    }

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    if let onCancel {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                    }
                }
        }
        .task {
            if let link = initialLink { await check(link.host, link.port, link.code) }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .idle:
            switch screen {
            case .start:
                PairWithNostromoView(onScan: { screen = .scanner },
                                     onEnterCode: { screen = .entry },
                                     onDigit: { digit in code = digit; screen = .entry })
            case .scanner:
                QRScannerView(onLink: { link in
                    address = link.host
                    code = link.code
                    Task { await check(link.host, link.port, link.code) }
                }, onEnterCode: { screen = .entry })
            case .entry:
                EnterCodeView(address: $address, code: $code) { host, port, digits in
                    Task { await check(host, port, digits) }
                }
            }
        case .checking:
            ProgressView("Checking the code…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .confirming(let confirmation), .pairing(let confirmation):
            ConfirmPairingView(model: model, confirmation: confirmation,
                               kindName: model.kindName, isPairing: isPairing)
        case .succeeded(let name):
            PairingSuccessView(name: name)
        case .failed(let failure, let failedAddress, let confirmation):
            VStack(spacing: 16) {
                PairingErrorBanner(failure: failure, address: failedAddress, kindName: model.kindName)
                if let confirmation {
                    ConfirmPairingView(model: model, confirmation: confirmation,
                                       kindName: model.kindName, isPairing: false)
                } else {
                    EnterCodeView(address: $address, code: $code, showsTryAgain: true) { host, port, digits in
                        Task { await check(host, port, digits) }
                    }
                }
            }
        }
    }

    private var isPairing: Bool {
        if case .pairing = model.step { return true }
        return false
    }

    private func check(_ host: String, _ port: UInt16, _ digits: String) async {
        await model.begin(address: host, port: port, code: digits)
    }
}
