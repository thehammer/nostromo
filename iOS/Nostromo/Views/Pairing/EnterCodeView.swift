// Nostromo iOS — EnterCodeView.swift
//
// The typed path: the server address (pre-filled with the last one used, PRD-AC5) and the six
// digits. Digits only; it submits on the sixth digit or on Return. `@FocusState` moves from the
// address to the code and back so the whole path works from a hardware keyboard with no touches
// (PRD-AC4).

import SwiftUI
import NostromoKit

struct EnterCodeView: View {
    @Binding var address: String
    @Binding var code: String
    /// After a failure the address and code stay put and one tap sends them again.
    var showsTryAgain = false
    /// Host, port and six digits, once the address is usable and the code is complete.
    let onSubmit: (String, UInt16, String) -> Void

    private enum Field { case address, code }
    @FocusState private var focus: Field?

    var body: some View {
        Form {
            Section("Server address") {
                TextField("10.0.0.5", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .focused($focus, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { focus = .code }
            }
            Section("Code") {
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .code)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter { $0.isASCII && $0.isNumber }.prefix(6))
                        if digits != new { code = digits }
                        if digits.count == 6 { submit() }
                    }
            }
            if showsTryAgain {
                Section { Button("Try Again", action: submit).disabled(!PairLink.isValidCode(code)) }
            }
        }
        .navigationTitle("Enter Code")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focus = address.isEmpty ? .address : .code }
    }

    private func submit() {
        guard PairLink.isValidCode(code), let target = Self.parse(address: address) else { return }
        onSubmit(target.host, target.port, code)
    }

    /// `10.0.0.5`, `10.0.0.5:47101`, `kobe.local`, `[fd00::1]:47101`.
    static func parse(address: String) -> (host: String, port: UInt16)? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let defaultPort = ConnectionSettings.webSocketPort
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let host = String(text[text.startIndex...close])
            let rest = text[text.index(after: close)...]
            guard PairLink.isValidHost(host) else { return nil }
            if rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), port > 0 { return (host, port) }
            return rest.isEmpty ? (host, defaultPort) : nil
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = UInt16(parts[1]), port > 0, PairLink.isValidHost(String(parts[0])) {
            return (String(parts[0]), port)
        }
        return parts.count == 1 && PairLink.isValidHost(text) ? (text, defaultPort) : nil
    }
}
