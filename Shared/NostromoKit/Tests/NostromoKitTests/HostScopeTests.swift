// NostromoKit — HostScopeTests.swift
//
// Which Macs' content the phone shows (W11 slice 2). What these guard:
//   * `HostScope.matches(host:egress:)` is the one filter: All shows everything, Work and Personal
//     filter by a host's egress, a named host matches by NAME whatever its egress;
//   * the scope survives a relaunch as one string, and anything unrecognised reads as All;
//   * a stored scope the hosts no longer support (a vanished host, a kind with no host) resolves to
//     All instead of an empty screen;
//   * the picker offers Work/Personal only when a host of that kind exists, the primary first;
//   * a host that is not connected says when it was last heard from;
//   * the roster remembers a satellite across a `Hosts` frame that no longer lists it (its egress and
//     last-seen time survive), and the primary is always the one personal entry named by the caller;
//   * `Hosts` timestamps decode (and a value that is not a timestamp is absent, not an error).

import XCTest
@testable import NostromoKit

final class HostScopeTests: XCTestCase {

    // 2027-01-15T08:00:00Z, a whole second.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ name: String, _ egress: HostEgress, primary: Bool = false,
                       connected: Bool = true, lastSeen: Date? = nil) -> HostEntry {
        HostEntry(name: name, egress: egress, isPrimary: primary, connected: connected, lastSeen: lastSeen)
    }

    private func info(_ name: String, _ egress: HostEgress, lastSeen: Date? = nil,
                      connectedSince: Date? = nil) -> HostInfoWire {
        HostInfoWire(name: name, egress: egress, connectedSince: connectedSince, lastSeen: lastSeen)
    }

    // MARK: - matches

    func testMatchesFollowsTheScopeByEgressOrByName() {
        // scope -> (a "kobe" host with work egress, a "kobe" host with personal egress)
        let matrix: [(scope: HostScope, work: Bool, personal: Bool)] = [
            (.all,              true,  true),
            (.work,             true,  false),
            (.personal,         false, true),
            (.host("kobe"),     true,  true),    // by name: egress is irrelevant
            (.host("studio"),   false, false),   // another name matches nothing
        ]
        for row in matrix {
            XCTAssertEqual(row.scope.matches(host: "kobe", egress: .work), row.work,
                           "\(row.scope) vs host kobe with work egress")
            XCTAssertEqual(row.scope.matches(host: "kobe", egress: .personal), row.personal,
                           "\(row.scope) vs host kobe with personal egress")
        }
    }

    func testANamedHostScopeMatchesTheExactNameOnly() {
        XCTAssertFalse(HostScope.host("kobe").matches(host: "kobe-2", egress: .work))
        XCTAssertFalse(HostScope.host("kobe-2").matches(host: "kobe", egress: .work))
        XCTAssertFalse(HostScope.host("").matches(host: "kobe", egress: .work))
    }

    func testOnlyANamedHostScopeIsASingleHost() {
        XCTAssertFalse(HostScope.all.isSingleHost)
        XCTAssertFalse(HostScope.work.isSingleHost)
        XCTAssertFalse(HostScope.personal.isSingleHost)
        XCTAssertTrue(HostScope.host("kobe").isSingleHost)
    }

    // MARK: - Persistence

    func testStorageValueIsTheOneStringKeptForEachScope() {
        XCTAssertEqual(HostScope.all.storageValue, "all")
        XCTAssertEqual(HostScope.work.storageValue, "work")
        XCTAssertEqual(HostScope.personal.storageValue, "personal")
        XCTAssertEqual(HostScope.host("kobe").storageValue, "host:kobe")
    }

    func testEveryScopeRoundTripsThroughItsStorageValue() {
        let scopes: [HostScope] = [
            .all, .work, .personal,
            .host("kobe"),
            .host("My Mac"),                 // spaces
            .host("studio: upstairs"),       // a colon and a space
            .host("a:b:c"),
            .host("host:kobe"),              // the prefix inside the name
            .host("work"),                   // a name that is also a kind
            .host("all"),
        ]
        for scope in scopes {
            XCTAssertEqual(HostScope(storageValue: scope.storageValue), scope,
                           "\(scope) must survive a relaunch")
        }
    }

    func testNothingOrGarbageOrAnEmptyHostNameReadsAsAll() {
        let unreadable: [String?] = [nil, "", "garbage", "host:", "host", "Work", "PERSONAL", "ALL",
                                     " host:kobe", "hosts:kobe", "all ", "work\n"]
        for stored in unreadable {
            XCTAssertEqual(HostScope(storageValue: stored), .all, "stored value \(String(describing: stored))")
        }
    }

    // MARK: - resolved(against:)

    func testAScopeNamingAHostThatIsGoneResolvesToAll() {
        let hosts = [entry("Sendai", .personal, primary: true), entry("kobe", .work)]
        XCTAssertEqual(HostScope.host("kobe").resolved(against: hosts), .host("kobe"))
        XCTAssertEqual(HostScope.host("Sendai").resolved(against: hosts), .host("Sendai"),
                       "The primary is a host by its own name")
        XCTAssertEqual(HostScope.host("ghost").resolved(against: hosts), .all)
        XCTAssertEqual(HostScope.host("KOBE").resolved(against: hosts), .all, "Names are exact")
    }

    func testWorkResolvesToAllWhenNoHostIsWork() {
        let onlyPrimaryAndPersonal = [entry("Sendai", .personal, primary: true), entry("studio", .personal)]
        XCTAssertEqual(HostScope.work.resolved(against: onlyPrimaryAndPersonal), .all)
        let withWork = onlyPrimaryAndPersonal + [entry("kobe", .work)]
        XCTAssertEqual(HostScope.work.resolved(against: withWork), .work)
    }

    func testPersonalResolvesToAllWhenNoHostIsPersonal() {
        let onlyWork = [entry("kobe", .work), entry("amber", .work)]
        XCTAssertEqual(HostScope.personal.resolved(against: onlyWork), .all)
        XCTAssertEqual(HostScope.personal.resolved(against: onlyWork + [entry("studio", .personal)]), .personal)
    }

    func testAllAlwaysResolvesToAll() {
        XCTAssertEqual(HostScope.all.resolved(against: []), .all)
        XCTAssertEqual(HostScope.all.resolved(against: [entry("kobe", .work)]), .all)
    }

    func testAHostThatIsNotConnectedStillSupportsItsScope() {
        let hosts = [entry("Sendai", .personal, primary: true), entry("kobe", .work, connected: false)]
        XCTAssertEqual(HostScope.host("kobe").resolved(against: hosts), .host("kobe"))
        XCTAssertEqual(HostScope.work.resolved(against: hosts), .work)
    }

    // MARK: - HostScopeOptions.options

    func testOptionsListAllThenKindsThenThePrimaryThenSatellitesByName() {
        let hosts = [entry("studio", .personal), entry("kobe", .work), entry("Zulu", .personal, primary: true),
                     entry("amber", .work)]
        XCTAssertEqual(HostScopeOptions.options(for: hosts),
                       [.all, .work, .personal, .host("Zulu"), .host("amber"), .host("kobe"), .host("studio")],
                       "The primary comes first even though its name sorts last")
    }

    func testOptionsWithOnlyThePrimaryOfferAllPersonalAndThePrimary() {
        let hosts = [entry("Sendai", .personal, primary: true)]
        XCTAssertEqual(HostScopeOptions.options(for: hosts), [.all, .personal, .host("Sendai")],
                       "No Work option while no host is work")
    }

    func testOptionsHidePersonalWhenNoHostIsPersonalAndWorkWhenNoHostIsWork() {
        XCTAssertEqual(HostScopeOptions.options(for: [entry("kobe", .work)]),
                       [.all, .work, .host("kobe")])
        XCTAssertEqual(HostScopeOptions.options(for: [entry("Sendai", .personal, primary: true),
                                                      entry("studio", .personal)]),
                       [.all, .personal, .host("Sendai"), .host("studio")])
    }

    func testOrderedPutsThePrimaryFirstThenSatellitesByName() {
        let hosts = [entry("kobe", .work), entry("Sendai", .personal, primary: true), entry("amber", .work)]
        XCTAssertEqual(HostScopeOptions.ordered(hosts).map(\.name), ["Sendai", "amber", "kobe"])
    }

    // MARK: - Labels

    func testEachOptionHasItsOwnNonEmptyLabelAndSpokenLabel() {
        let scopes: [HostScope] = [.all, .work, .personal, .host("kobe"), .host("studio")]
        let labels = scopes.map { HostScopeOptions.label(for: $0) }
        let spoken = scopes.map { HostScopeOptions.accessibilityLabel(for: $0) }
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(spoken.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(labels).count, scopes.count, "Labels must tell the options apart: \(labels)")
        XCTAssertEqual(Set(spoken).count, scopes.count, "Spoken labels must tell the options apart: \(spoken)")
    }

    func testTheKindsAndTheHostAreCalledWhatTheyAre() {
        XCTAssertEqual(HostScopeOptions.label(for: .all), "All")
        XCTAssertEqual(HostScopeOptions.label(for: .work), "Work")
        XCTAssertEqual(HostScopeOptions.label(for: .personal), "Personal")
        XCTAssertEqual(HostScopeOptions.label(for: .host("kobe")), "kobe")
        XCTAssertTrue(HostScopeOptions.accessibilityLabel(for: .host("kobe")).contains("kobe"))
        XCTAssertTrue(HostScopeOptions.accessibilityLabel(for: .work).lowercased().contains("work"))
        XCTAssertTrue(HostScopeOptions.accessibilityLabel(for: .personal).lowercased().contains("personal"))
    }

    // MARK: - lastKnownLabel

    func testAConnectedHostHasNoLastKnownLabelEvenWithALastSeenTime() {
        let host = entry("kobe", .work, connected: true, lastSeen: now.addingTimeInterval(-300))
        XCTAssertNil(HostScopeOptions.lastKnownLabel(host, now: now))
    }

    func testADisconnectedHostNeverHeardFromSaysLastKnown() {
        let host = entry("kobe", .work, connected: false, lastSeen: nil)
        XCTAssertEqual(HostScopeOptions.lastKnownLabel(host, now: now), "Last known")
    }

    func testADisconnectedHostSaysWhenItWasLastSeenRelativeToTheInjectedNow() throws {
        let seen = now.addingTimeInterval(-300)
        let host = entry("kobe", .work, connected: false, lastSeen: seen)

        let label = try XCTUnwrap(HostScopeOptions.lastKnownLabel(host, now: now))

        XCTAssertTrue(label.hasPrefix("Last seen "), label)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        XCTAssertEqual(label, "Last seen \(formatter.localizedString(for: seen, relativeTo: now))")
        let later = try XCTUnwrap(HostScopeOptions.lastKnownLabel(host, now: now.addingTimeInterval(7_200)))
        XCTAssertNotEqual(label, later, "The label follows `now`, so it must change as time passes")
    }

    // MARK: - HostRoster

    func testAHostsFrameMarksEveryListedSatelliteConnectedWithItsEgressAndLastSeen() {
        var roster = HostRoster()
        let seen = now.addingTimeInterval(-30)

        roster.apply([info("kobe", .work, lastSeen: seen), info("studio", .personal)])

        XCTAssertEqual(roster.records["kobe"], HostRoster.Record(egress: .work, connected: true, lastSeen: seen))
        XCTAssertEqual(roster.records["studio"], HostRoster.Record(egress: .personal, connected: true, lastSeen: nil))
        XCTAssertEqual(roster.records.count, 2)
    }

    func testASatelliteAbsentFromALaterFrameIsDisconnectedButKeepsItsEgressAndLastSeen() {
        var roster = HostRoster()
        let seen = now.addingTimeInterval(-30)
        roster.apply([info("kobe", .work, lastSeen: seen), info("studio", .personal)])

        roster.apply([info("studio", .personal)])

        XCTAssertEqual(roster.records["kobe"], HostRoster.Record(egress: .work, connected: false, lastSeen: seen),
                       "A host that dropped is not forgotten")
        XCTAssertEqual(roster.records["studio"]?.connected, true)
    }

    func testAnEmptyHostsFrameDisconnectsEveryone() {
        var roster = HostRoster()
        roster.apply([info("kobe", .work), info("studio", .personal)])

        roster.apply([])

        XCTAssertEqual(roster.records.count, 2)
        XCTAssertEqual(roster.records.values.map(\.connected), [false, false])
    }

    func testASatelliteThatComesBackIsConnectedAgainWithItsNewLastSeen() {
        var roster = HostRoster()
        let first = now.addingTimeInterval(-600)
        let second = now.addingTimeInterval(-5)
        roster.apply([info("kobe", .work, lastSeen: first)])
        roster.apply([])

        roster.apply([info("kobe", .work, lastSeen: second)])

        XCTAssertEqual(roster.records["kobe"], HostRoster.Record(egress: .work, connected: true, lastSeen: second))
    }

    func testAFrameWithoutALastSeenKeepsTheLastOneTheRosterHad() {
        var roster = HostRoster()
        let seen = now.addingTimeInterval(-90)
        roster.apply([info("kobe", .work, lastSeen: seen)])

        roster.apply([info("kobe", .work, lastSeen: nil)])

        XCTAssertEqual(roster.records["kobe"]?.lastSeen, seen)
        XCTAssertEqual(roster.records["kobe"]?.connected, true)
    }

    func testALaterFramesEgressReplacesTheEarlierOne() {
        var roster = HostRoster()
        roster.apply([info("studio", .work)])

        roster.apply([info("studio", .personal)])

        XCTAssertEqual(roster.records["studio"]?.egress, .personal)
    }

    func testRemoveAllForgetsEverySatellite() {
        var roster = HostRoster()
        roster.apply([info("kobe", .work)])

        roster.removeAll()

        XCTAssertEqual(roster, HostRoster())
        XCTAssertEqual(roster.entries(primaryName: "Sendai", hostsWithContent: [], linkLive: true).map(\.name),
                       ["Sendai"])
    }

    // MARK: - HostRoster.entries

    func testEntriesStartWithThePrimaryAsAPersonalConnectedHostNamedByTheCaller() throws {
        var roster = HostRoster()
        roster.apply([info("studio", .personal), info("kobe", .work)])

        let entries = roster.entries(primaryName: "Sendai", hostsWithContent: [], linkLive: true)

        XCTAssertEqual(entries.map(\.name), ["Sendai", "kobe", "studio"], "Primary first, then by name")
        let primary = try XCTUnwrap(entries.first)
        XCTAssertTrue(primary.isPrimary)
        XCTAssertEqual(primary.egress, .personal)
        XCTAssertTrue(primary.connected)
        XCTAssertEqual(entries.filter(\.isPrimary).count, 1)
        XCTAssertEqual(entries.first { $0.name == "kobe" }?.egress, .work)
        XCTAssertEqual(entries.first { $0.name == "studio" }?.egress, .personal)
    }

    func testEntriesWithTheLinkDownMarkEveryHostDisconnectedButKeepEgressAndLastSeen() throws {
        var roster = HostRoster()
        let seen = now.addingTimeInterval(-45)
        roster.apply([info("kobe", .work, lastSeen: seen), info("studio", .personal)])

        let entries = roster.entries(primaryName: "Sendai", hostsWithContent: [], linkLive: false)

        XCTAssertTrue(entries.allSatisfy { !$0.connected }, "Nothing is connected while the phone's own link is down")
        let kobe = try XCTUnwrap(entries.first { $0.name == "kobe" })
        XCTAssertEqual(kobe.egress, .work)
        XCTAssertEqual(kobe.lastSeen, seen)
    }

    func testEntriesForASatelliteThatDroppedAreDisconnectedWhileTheOthersAreConnected() throws {
        var roster = HostRoster()
        roster.apply([info("kobe", .work), info("studio", .personal)])
        roster.apply([info("studio", .personal)])

        let entries = roster.entries(primaryName: "Sendai", hostsWithContent: [], linkLive: true)

        XCTAssertEqual(entries.first { $0.name == "kobe" }?.connected, false)
        XCTAssertEqual(entries.first { $0.name == "studio" }?.connected, true)
        XCTAssertEqual(entries.first { $0.isPrimary }?.connected, true)
    }

    func testAHostWithContentThatWasNeverListedIsAWorkHostThatIsNotConnected() throws {
        let roster = HostRoster()

        let entries = roster.entries(primaryName: "Sendai", hostsWithContent: ["mystery"], linkLive: true)

        let mystery = try XCTUnwrap(entries.first { $0.name == "mystery" })
        XCTAssertEqual(mystery.egress, .work, "The strict reading")
        XCTAssertFalse(mystery.connected)
        XCTAssertNil(mystery.lastSeen)
        XCTAssertFalse(mystery.isPrimary)
    }

    func testAHostWithContentThatIsOnRecordUsesTheRecordNotTheStrictDefault() throws {
        var roster = HostRoster()
        roster.apply([info("studio", .personal)])

        let entries = roster.entries(primaryName: "Sendai", hostsWithContent: ["studio"], linkLive: true)

        XCTAssertEqual(entries.filter { $0.name == "studio" }.count, 1, "One entry per host")
        XCTAssertEqual(entries.first { $0.name == "studio" }?.egress, .personal)
        XCTAssertEqual(entries.first { $0.name == "studio" }?.connected, true)
    }

    func testASatelliteNamedLikeThePrimaryDoesNotProduceASecondEntry() throws {
        var roster = HostRoster()
        roster.apply([info("Sendai", .work), info("kobe", .work)])

        let entries = roster.entries(primaryName: "Sendai", hostsWithContent: ["Sendai"], linkLive: true)

        XCTAssertEqual(entries.map(\.name), ["Sendai", "kobe"])
        let primary = try XCTUnwrap(entries.first)
        XCTAssertTrue(primary.isPrimary)
        XCTAssertEqual(primary.egress, .personal, "The primary is the operator's own Mac")
    }

    func testAHostEntryIsIdentifiedByItsNameAndThePrimaryByTheEmptyString() {
        XCTAssertEqual(entry("Sendai", .personal, primary: true).id, "")
        XCTAssertEqual(entry("kobe", .work).id, "kobe")
    }

    // MARK: - HostInfoWire timestamps

    func testAHostsFrameDecodesConnectedSinceAndLastSeen() throws {
        let json = """
        {"type":"hosts","hosts":[
          {"name":"kobe","egress":"work","connected_since":"2027-01-15T07:00:00Z","last_seen":"2027-01-15T07:59:30.250Z"},
          {"name":"studio","egress":"personal","last_seen":"2027-01-15T07:55:00+00:00"},
          {"name":"plain","egress":"personal"},
          {"name":"junk","egress":"work","connected_since":"a while ago","last_seen":""}
        ]}
        """
        guard case let .hosts(hosts) = ServerMsg.decode(from: Data(json.utf8)) else {
            return XCTFail("expected a hosts frame")
        }
        XCTAssertEqual(hosts.map(\.name), ["kobe", "studio", "plain", "junk"])

        let kobe = hosts[0]
        XCTAssertEqual(try XCTUnwrap(kobe.connectedSince).timeIntervalSince1970, 1_799_996_400, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(kobe.lastSeen).timeIntervalSince1970, 1_799_999_970.25, accuracy: 0.001,
                       "Fractional seconds are kept")

        let studio = hosts[1]
        XCTAssertNil(studio.connectedSince)
        XCTAssertEqual(try XCTUnwrap(studio.lastSeen).timeIntervalSince1970, 1_799_999_700, accuracy: 0.001,
                       "A numeric UTC offset is a timestamp too")

        XCTAssertNil(hosts[2].connectedSince, "A primary that sends none gives none")
        XCTAssertNil(hosts[2].lastSeen)

        XCTAssertNil(hosts[3].connectedSince, "A value that is not a timestamp is absent, not an error")
        XCTAssertNil(hosts[3].lastSeen)
        XCTAssertEqual(hosts[3].egress, .work, "The rest of the entry still decodes")
    }

    func testAHostWithAnUnknownOrMissingEgressIsAWorkHost() {
        let json = #"{"type":"hosts","hosts":[{"name":"a","egress":"mystery"},{"name":"b"},{"name":"c","egress":"personal"}]}"#
        guard case let .hosts(hosts) = ServerMsg.decode(from: Data(json.utf8)) else {
            return XCTFail("expected a hosts frame")
        }
        XCTAssertEqual(hosts.map(\.egress), [.work, .work, .personal])
    }
}
