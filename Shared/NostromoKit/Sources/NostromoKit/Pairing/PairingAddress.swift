// NostromoKit — PairingAddress.swift
//
// Which pairing addresses iOS's App Transport Security lets a plain `ws://` socket reach. The app's
// only exception is `NSAllowsLocalNetworking` (Info.plist; never `NSAllowsArbitraryLoads`), which
// covers IPv4 and IPv6 literals, `.local` names and single-label names. A full domain name
// (`mac.tailnet.ts.net`) is outside it, and the list cannot be extended at run time: an
// `NSExceptionDomains` entry would have to be written into the app for one operator's domain.
// This only decides which hint to show; it blocks nothing.

import Foundation

public enum PairingAddress {

    /// Whether `host` is an IP literal, a `.local` name or a single-label name.
    public static func isLocalNetworkingForm(_ host: String) -> Bool {
        let name = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return true }
        if name.contains(":") { return true }                    // IPv6 literal, bracketed or not
        if isIPv4(name) { return true }
        if name.hasSuffix(".local") || name.hasSuffix(".local.") { return true }
        return !name.contains(".")                               // single label
    }

    private static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber } && (Int(part) ?? 256) <= 255
        }
    }
}
