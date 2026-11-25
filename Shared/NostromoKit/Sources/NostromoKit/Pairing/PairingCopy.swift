// NostromoKit — PairingCopy.swift
//
// Every sentence the pairing flow and the connection banners show, verbatim from the PRD
// (`docs/prds/daemon-pairing-flow.md`, "Failure copy" and "Final v1 copy") and Ada's D1/D6 sign-offs.
// One file so a wording test can pin them and no view hand-types a sentence. `address` and `kind` are
// the real ones ("10.0.0.5", "iPhone" / "iPad").

import Foundation

public enum PairingCopy {

    // MARK: Failures (PRD "Failure copy")

    public static func expired() -> String {
        "That code has expired. Codes last five minutes. Make a new one on your Mac and enter it here."
    }
    public static func invalid() -> String {
        "That code isn't right. Check the six digits and try again."
    }
    public static func unreachable(address: String) -> String {
        "Can't reach Nostromo at \(address). If you're away from home, turn on your VPN and try again."
    }
    /// D1: the fifth state. Buttons: Open Settings, Try Again.
    public static func localNetworkDenied(address: String) -> String {
        "Nostromo can't use your local network, so it can't reach \(address) on this Wi-Fi. "
            + "Turn on Local Network for Nostromo in Settings, or use your VPN."
    }
    /// The address cannot be used at all (a malformed host); nothing was sent to it.
    public static func badAddress(address: String) -> String {
        "\(address) isn't an address Nostromo can connect to. Use the server's IP address, "
            + "such as 10.0.0.5, or a name ending in .local."
    }
    public static func noLongerPaired(kind: String) -> String {
        "This \(kind) is no longer paired with Nostromo. Pair it again to reconnect."
    }

    // MARK: Address form (App Transport Security)

    /// Shown under the address field. iOS lets this app open a plain `ws://` socket only to an IP
    /// address (a VPN address included), a `.local` name or a single-word name: the exception is
    /// `NSAllowsLocalNetworking`, and it cannot be widened to the operator's own domain at run time.
    public static let addressHint =
        "Use the server's IP address (for example 10.0.0.5 or its VPN address) or a .local name. "
        + "A full domain name such as mac.example.com can't be used."

    /// Added under "can't reach" when `address` is a full domain name, which iOS blocks for this app
    /// whether or not the server is up. `nil` for an address that is not blocked on those grounds.
    public static func addressFormHint(address: String) -> String? {
        PairingAddress.isLocalNetworkingForm(address) ? nil : addressHint
    }

    // MARK: Banners over last-known content

    public static func unreachableBanner(address: String) -> String {
        "Can't reach Nostromo at \(address). If you're away from home, turn on your VPN."
    }
    public static func localNetworkBanner(address: String) -> String {
        "Nostromo can't use your local network to reach \(address). Turn it on in Settings or use your VPN."
    }

    // MARK: Pairing screens

    public static let title = "Pair with Nostromo"
    public static let instructions =
        "On your Mac, choose Pair a Device… in Nostromo (or run `nostromo device pair` on your server). "
        + "Then scan the code it shows."
    public static func confirmation(kind: String, address: String) -> String {
        "Pair this \(kind) with Nostromo at \(address)?"
    }
    /// D6, same server.
    public static func replacesPairing(kind: String) -> String {
        "This replaces this \(kind)'s current pairing. The old one will be revoked."
    }
    /// D6, different server.
    public static func differentServer(kind: String, old: String, new: String) -> String {
        "This \(kind) is paired with Nostromo at \(old). Pairing with \(new) disconnects it from \(old) "
            + "and removes its Nostromo content."
    }

    // MARK: Settings

    public static func forgotten(kind: String) -> String {
        "Forgotten on this \(kind). Revoke it from your Mac's Devices list when you can."
    }

    /// Q2, the only sentence in the app about mail, calendar or todos (Fred tab, Teri tab, Settings).
    public static let notShared = "Mail, calendar and todos stay on your Mac in this version."
}
