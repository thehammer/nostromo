// NostromoKit — PairLink.swift
//
// The `nostromo://pair?v=1&host=&port=&code=` link a `nostromo device pair` QR carries (PRD-AC6).
// Pure and strict: anything malformed is an error, and a malformed link never sends anything
// (W11-11).

import Foundation

public struct PairLink: Equatable {
    public let host: String
    public let port: UInt16
    /// Six digits.
    public let code: String

    public enum ParseError: Error, Equatable {
        case notAPairLink
        case unsupportedVersion
        case badHost
        case badPort
        case badCode
    }

    public init(host: String, port: UInt16, code: String) {
        self.host = host
        self.port = port
        self.code = code
    }

    public static func parse(_ url: URL) -> Result<PairLink, ParseError> {
        guard url.scheme?.lowercased() == "nostromo", url.host?.lowercased() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return .failure(.notAPairLink) }

        // A repeated key is ambiguous: refuse rather than pick one.
        var values: [String: String] = [:]
        for item in items {
            if values[item.name] != nil { return .failure(.notAPairLink) }
            values[item.name] = item.value ?? ""
        }

        guard values["v"] == "1" else { return .failure(.unsupportedVersion) }
        guard let host = values["host"], isValidHost(host) else { return .failure(.badHost) }
        guard let portText = values["port"], !portText.isEmpty,
              portText.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = UInt16(portText), port >= 1
        else { return .failure(.badPort) }
        guard let code = values["code"], isValidCode(code) else { return .failure(.badCode) }
        return .success(PairLink(host: host, port: port, code: code))
    }

    /// A code is exactly six ASCII digits.
    public static func isValidCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// A host is non-empty and has nothing that would make it more than a host name or address.
    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        return host.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || "-._:[]".contains(ch))
        }
    }
}
