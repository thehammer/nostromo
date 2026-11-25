// NostromoKit — PairLinkTests.swift
//
// The `nostromo://pair?v=1&host=&port=&code=` link a `nostromo device pair` QR carries (PRD-AC6).
// Parsing is strict: anything malformed is an error, so a malformed link never sends anything
// (W11-11). Links are built with `URLComponents` so every value is percent-encoded the way a real
// QR payload would be.

import XCTest
@testable import NostromoKit

final class PairLinkTests: XCTestCase {

    // MARK: Helpers

    private func link(scheme: String = "nostromo", host linkHost: String = "pair",
                      _ items: [(String, String?)]) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = linkHost
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return components.url!
    }

    private func valid(v: String? = "1", host: String? = "192.168.1.5", port: String? = "47101",
                       code: String? = "123456") -> URL {
        var items: [(String, String?)] = []
        if let v { items.append(("v", v)) }
        if let host { items.append(("host", host)) }
        if let port { items.append(("port", port)) }
        if let code { items.append(("code", code)) }
        return link(items)
    }

    private func assertFails(_ url: URL, _ expected: PairLink.ParseError,
                             file: StaticString = #filePath, line: UInt = #line) {
        switch PairLink.parse(url) {
        case .success(let link):
            XCTFail("expected \(expected) for \(url), parsed \(link)", file: file, line: line)
        case .failure(let error):
            XCTAssertEqual(error, expected, "for \(url)", file: file, line: line)
        }
    }

    private func assertParses(_ url: URL, host: String, port: UInt16, code: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        switch PairLink.parse(url) {
        case .success(let parsed):
            XCTAssertEqual(parsed, PairLink(host: host, port: port, code: code), file: file, line: line)
        case .failure(let error):
            XCTFail("expected success for \(url), got \(error)", file: file, line: line)
        }
    }

    // MARK: - Valid

    func testAValidLinkParses() {
        assertParses(valid(), host: "192.168.1.5", port: 47101, code: "123456")
    }

    func testAnIPv4AHostNameAndABracketedIPv6HostAreAccepted() {
        assertParses(valid(host: "10.0.0.7"), host: "10.0.0.7", port: 47101, code: "123456")
        assertParses(valid(host: "hammers-mac.local"), host: "hammers-mac.local", port: 47101, code: "123456")
        assertParses(valid(host: "[fe80::1]"), host: "[fe80::1]", port: 47101, code: "123456")
    }

    func testThePortBoundsAreAccepted() {
        assertParses(valid(port: "1"), host: "192.168.1.5", port: 1, code: "123456")
        assertParses(valid(port: "65535"), host: "192.168.1.5", port: 65535, code: "123456")
    }

    func testACodeWithLeadingZerosIsKept() {
        assertParses(valid(code: "000123"), host: "192.168.1.5", port: 47101, code: "000123")
    }

    // MARK: - Scheme, host and version

    func testAWrongSchemeIsNotAPairLink() {
        assertFails(link(scheme: "https", [("v", "1"), ("host", "h"), ("port", "1"), ("code", "123456")]), .notAPairLink)
    }

    func testAWrongLinkHostIsNotAPairLink() {
        assertFails(link(host: "other", [("v", "1"), ("host", "h"), ("port", "1"), ("code", "123456")]), .notAPairLink)
    }

    func testALinkWithNoQueryIsNotAPairLink() {
        assertFails(URL(string: "nostromo://pair")!, .notAPairLink)
    }

    func testAnUnsupportedVersionIsRefused() {
        assertFails(valid(v: "2"), .unsupportedVersion)
        assertFails(valid(v: "0"), .unsupportedVersion)
        assertFails(valid(v: ""), .unsupportedVersion)
        assertFails(valid(v: "1.0"), .unsupportedVersion)
    }

    func testAMissingVersionIsRefused() {
        assertFails(valid(v: nil), .unsupportedVersion)
    }

    func testARepeatedKeyIsAmbiguousAndRefused() {
        let base: [(String, String?)] = [("v", "1"), ("host", "192.168.1.5"), ("port", "47101"), ("code", "123456")]
        for key in ["v", "host", "port", "code"] {
            let value = base.first { $0.0 == key }!.1
            assertFails(link(base + [(key, value)]), .notAPairLink)
        }
    }

    // MARK: - Host

    func testAMissingOrEmptyHostIsRefused() {
        assertFails(valid(host: nil), .badHost)
        assertFails(valid(host: ""), .badHost)
    }

    func testAHostWithSpacesASlashOrAnAtSignIsRefused() {
        assertFails(valid(host: "my host"), .badHost)
        assertFails(valid(host: "a/b"), .badHost)
        assertFails(valid(host: "user@host"), .badHost)
        assertFails(valid(host: "evil.example/path"), .badHost)
    }

    // MARK: - Port

    func testABadPortIsRefused() {
        assertFails(valid(port: nil), .badPort)
        assertFails(valid(port: ""), .badPort)
        assertFails(valid(port: "0"), .badPort)
        assertFails(valid(port: "65536"), .badPort)
        assertFails(valid(port: "abc"), .badPort)
        assertFails(valid(port: "-1"), .badPort)
        assertFails(valid(port: "47101a"), .badPort)
    }

    // MARK: - Code

    func testACodeThatIsNotExactlySixDigitsIsRefused() {
        assertFails(valid(code: nil), .badCode)
        assertFails(valid(code: ""), .badCode)
        assertFails(valid(code: "12345"), .badCode)
        assertFails(valid(code: "1234567"), .badCode)
        assertFails(valid(code: "12345a"), .badCode)
        assertFails(valid(code: "abcdef"), .badCode)
        assertFails(valid(code: "123 456"), .badCode)
    }

    func testUnicodeDigitsAreNotDigits() {
        // Arabic-Indic digits one to six.
        assertFails(valid(code: "\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}"), .badCode)
        // Fullwidth digits.
        assertFails(valid(code: "\u{FF11}\u{FF12}\u{FF13}\u{FF14}\u{FF15}\u{FF16}"), .badCode)
    }

    func testIsValidCode() {
        XCTAssertTrue(PairLink.isValidCode("123456"))
        XCTAssertTrue(PairLink.isValidCode("000000"))
        XCTAssertFalse(PairLink.isValidCode("12345"))
        XCTAssertFalse(PairLink.isValidCode("1234567"))
        XCTAssertFalse(PairLink.isValidCode("12345a"))
        XCTAssertFalse(PairLink.isValidCode(""))
        XCTAssertFalse(PairLink.isValidCode("\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}"))
    }
}
