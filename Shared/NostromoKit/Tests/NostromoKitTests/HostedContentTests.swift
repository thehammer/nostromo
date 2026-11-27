// NostromoKit — HostedContentTests.swift
//
// What a satellite's Focuses and Perri frames become on the phone (W11 slice 2): the sections the
// views draw under a host scope. What these guard:
//   * focuses and PRs are keyed by (host, tag): a satellite's tag may equal the primary's and neither
//     side's row, session badge or PR label changes because of it;
//   * the host scope narrows the sections (work / personal / one host), the primary is first, then
//     hosts by name, and a Mac with nothing to show has no section;
//   * a section carries its Mac's name unless the scope is one Mac and one section is shown;
//   * rendering never asks about egress: the REAL work-shaped frames (pseudonymous tags and repos,
//     empty titles) render from the fields they carry and the fixed `PR #N · ...` phrase, with no
//     link and no invented org header, while the REAL personal frames show titles, authors, links
//     and org headers;
//   * only https links are links, and only `r-` plus eight lower-case hex is a pseudonymous repo;
//   * a host that is not connected is marked last-known.
//
// The fixtures are `tests/fixtures/hosts/*.json`, captured from the Rust daemon's redaction output.

import XCTest
@testable import NostromoKit

final class HostedContentTests: XCTestCase {

    // 2027-01-15T08:00:00Z
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fixtures

    private enum FixtureProblem: Error { case missing, wrongShape }

    private func fixture(_ name: String, _ kind: String) throws -> Data {
        var url = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("tests/fixtures/hosts/\(name).\(kind).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("fixture not found at \(url.path)")
            throw FixtureProblem.missing
        }
        return try Data(contentsOf: url)
    }

    private func perriState(_ kind: String) throws -> HostedPerriState {
        guard case let .perriState(_, queue, current) = ServerMsg.decodeHosted(from: try fixture("perri_state", kind)).msg
        else {
            XCTFail("perri_state.\(kind).json did not decode as a perri_state frame")
            throw FixtureProblem.wrongShape
        }
        XCTAssertNil(current, "These fixtures carry no current PR")
        return HostedPerriState(queue: queue, currents: [:])
    }

    private func focusList(_ kind: String) throws -> [FocusMeta] {
        guard case let .focusRegistryUpdated(list) =
                ServerMsg.decodeHosted(from: try fixture("focus_registry_updated", kind)).msg else {
            XCTFail("focus_registry_updated.\(kind).json did not decode as a focus registry frame")
            throw FixtureProblem.wrongShape
        }
        return list
    }

    // MARK: - Builders

    private func entry(_ name: String, _ egress: HostEgress, primary: Bool = false, connected: Bool = true,
                       lastSeen: Date? = nil) -> HostEntry {
        HostEntry(name: name, egress: egress, isPrimary: primary, connected: connected, lastSeen: lastSeen)
    }

    /// The primary "Sendai", a work satellite "kobe", a personal satellite "studio": all connected.
    private var threeHosts: [HostEntry] {
        [entry("Sendai", .personal, primary: true), entry("kobe", .work), entry("studio", .personal)]
    }

    private func focus(_ tag: String, agent: String = "cody", project: String? = nil, org: String? = nil,
                       builtIn: Bool = false) -> FocusMeta {
        FocusMeta(tag: tag, displayName: agent.capitalized, agentName: agent, projectName: project, org: org,
                  isBuiltIn: builtIn, sessionSummary: nil)
    }

    private func session(_ tag: String, state: SessionState = .idle) -> SessionInfo {
        SessionInfo(tag: tag, agentName: "cody", viewName: "view", sessionId: nil, alive: true,
                    remoteControl: false, state: state, stopReason: nil, mcpBridgeConnected: nil)
    }

    private func snapshot(repo: String, number: Int) -> PrSnapshot {
        PrSnapshot(prNumber: number, repo: repo, title: "t", author: "a",
                   url: "https://github.com/\(repo)/pull/\(number)", diff: "", stale: false, error: nil,
                   ciChecks: [], additions: 1, deletions: 1, changedFiles: 1, headSha: "sha", diffTooLarge: false)
    }

    private func item(_ repo: String, _ number: Int, bucket: String = "needs_review", title: String = "",
                      author: String = "", url: String = "", changed: Int? = nil,
                      ci: CiState = .unknown) -> PrQueueItem {
        PrQueueItem(repo: repo, number: number, title: title, author: author, bucket: bucket,
                    newActivity: false, url: url, ciState: ci, headSha: "", changedLines: changed)
    }

    private func focusSections(primaryFocuses: [FocusMeta] = [],
                               primarySessions: [String: SessionInfo] = [:],
                               primaryPR: [String: (repo: String, number: Int)] = [:],
                               hostedFocuses: [String: [FocusMeta]] = [:],
                               hostedSessions: [String: [SessionInfo]] = [:],
                               hostedPerri: [String: HostedPerriState] = [:],
                               hosts: [HostEntry]? = nil,
                               scope: HostScope = .all) -> [FocusHostSection] {
        HostedFocuses.sections(
            primaryFocuses: primaryFocuses, primarySessions: primarySessions,
            primaryPR: { tag in
                if let pr = primaryPR[tag] { return (repo: pr.repo, number: pr.number) }
                return (repo: nil, number: nil)
            },
            hostedFocuses: hostedFocuses, hostedSessions: hostedSessions, hostedPerri: hostedPerri,
            hosts: hosts ?? threeHosts, scope: scope, now: now)
    }

    private func perriSections(_ hostedPerri: [String: HostedPerriState], hosts: [HostEntry]? = nil,
                               scope: HostScope = .all, includePrimary: Bool = false) -> [PerriHostSection] {
        HostedPerri.sections(hostedPerri: hostedPerri, hosts: hosts ?? threeHosts, scope: scope,
                             includePrimary: includePrimary, now: now)
    }

    private struct FocusLine { let meta: FocusMeta; let label: String; let secondary: String? }

    private func focusLines(_ rows: [FocusRow]) -> [FocusLine] {
        rows.compactMap {
            guard case let .focus(meta, label, secondary, _) = $0 else { return nil }
            return FocusLine(meta: meta, label: label, secondary: secondary)
        }
    }

    private func hasOrgHeader(_ rows: [FocusRow]) -> Bool {
        rows.contains { if case .orgHeader = $0 { return true } else { return false } }
    }

    private func onePerriHost(_ items: [PrQueueItem], host name: String = "kobe") -> [String: HostedPerriState] {
        [name: HostedPerriState(queue: items, currents: [:])]
    }

    // MARK: - Focuses: order, scope, emptiness

    func testFocusSectionsListThePrimaryFirstThenHostsByName() {
        let sections = focusSections(
            primaryFocuses: [focus("perri", agent: "perri", builtIn: true)],
            hostedFocuses: ["studio": [focus("s1")], "kobe": [focus("k1")]],
            hosts: [entry("studio", .personal), entry("kobe", .work), entry("Sendai", .personal, primary: true)])

        XCTAssertEqual(sections.map(\.host.name), ["Sendai", "kobe", "studio"])
        XCTAssertTrue(sections[0].host.isPrimary)
        XCTAssertEqual(focusLines(sections[1].rows).map(\.meta.tag), ["k1"])
        XCTAssertEqual(focusLines(sections[2].rows).map(\.meta.tag), ["s1"])
    }

    func testAMacWithNoFocusesHasNoSection() {
        let sections = focusSections(
            primaryFocuses: [],
            hostedFocuses: ["kobe": [], "studio": [focus("s1")]])

        XCTAssertEqual(sections.map(\.host.name), ["studio"], "Neither the empty primary nor the empty kobe")
    }

    func testAHostWithFocusesButNoEntryInHostsIsNotShown() {
        let sections = focusSections(hostedFocuses: ["ghost": [focus("g1")]])
        XCTAssertTrue(sections.isEmpty, "Only Macs the phone knows of are sections")
    }

    func testTheScopeNarrowsTheFocusSections() {
        let hosts = threeHosts + [entry("amber", .work)]
        func names(_ scope: HostScope) -> [String] {
            focusSections(primaryFocuses: [focus("p1")],
                          hostedFocuses: ["kobe": [focus("k1")], "studio": [focus("s1")], "amber": [focus("a1")]],
                          hosts: hosts, scope: scope).map(\.host.name)
        }
        XCTAssertEqual(names(.all), ["Sendai", "amber", "kobe", "studio"])
        XCTAssertEqual(names(.work), ["amber", "kobe"], "Work: the work satellites, never the primary")
        XCTAssertEqual(names(.personal), ["Sendai", "studio"], "Personal: the primary and the personal satellites")
        XCTAssertEqual(names(.host("kobe")), ["kobe"])
        XCTAssertEqual(names(.host("Sendai")), ["Sendai"])
        XCTAssertEqual(names(.host("nobody")), [])
    }

    func testASatelliteFocusListWithDuplicateTagsKeepsTheLastEntryOnce() {
        let sections = focusSections(hostedFocuses: ["kobe": [focus("k1", agent: "first"), focus("k2", agent: "other"),
                                                              focus("k1", agent: "second")]])

        let lines = focusLines(sections[0].rows)
        XCTAssertEqual(lines.map(\.meta.tag).sorted(), ["k1", "k2"])
        XCTAssertEqual(lines.first { $0.meta.tag == "k1" }?.meta.agentName, "second")
    }

    // MARK: - Focuses: keyed by (host, tag)

    func testASatelliteFocusWithThePrimarysTagStaysInItsOwnSectionAndTheirPRLabelsDoNotMix() throws {
        let primary = focus("cody-1", agent: "cody", project: "admin-portal", org: "Carefeed")
        let satellite = focus("cody-1", agent: "claudia", project: "other-project", org: "Carefeed")

        let sections = focusSections(
            primaryFocuses: [primary],
            primaryPR: ["cody-1": (repo: "acme/web", number: 42)],
            hostedFocuses: ["kobe": [satellite]],
            hostedPerri: ["kobe": HostedPerriState(queue: [],
                                                   currents: ["cody-1": snapshot(repo: "acme/api", number: 7)])])

        XCTAssertEqual(sections.map(\.host.name), ["Sendai", "kobe"])
        let primaryLine = try XCTUnwrap(focusLines(sections[0].rows).first)
        let satelliteLine = try XCTUnwrap(focusLines(sections[1].rows).first)
        XCTAssertEqual(primaryLine.meta, primary, "The primary's focus is still the primary's")
        XCTAssertEqual(satelliteLine.meta, satellite)
        XCTAssertEqual(primaryLine.secondary, "#42 · web", "The primary's PR, not kobe's")
        XCTAssertEqual(satelliteLine.secondary, "#7 · api", "Kobe's PR, not the primary's")
    }

    func testAPRUnderReviewOnOneSideNeverShowsOnTheOthersFocusWithTheSameTag() throws {
        let primary = focus("cody-1")
        let satellite = focus("cody-1")

        let onlyPrimaryHasAPR = focusSections(
            primaryFocuses: [primary], primaryPR: ["cody-1": (repo: "acme/web", number: 42)],
            hostedFocuses: ["kobe": [satellite]])
        XCTAssertEqual(try XCTUnwrap(focusLines(onlyPrimaryHasAPR[0].rows).first).secondary, "#42 · web")
        XCTAssertEqual(try XCTUnwrap(focusLines(onlyPrimaryHasAPR[1].rows).first).secondary, FocusPRLabel.noPR)

        let onlyKobeHasAPR = focusSections(
            primaryFocuses: [primary], hostedFocuses: ["kobe": [satellite]],
            hostedPerri: ["kobe": HostedPerriState(queue: [], currents: ["cody-1": snapshot(repo: "acme/api", number: 7)])])
        XCTAssertEqual(try XCTUnwrap(focusLines(onlyKobeHasAPR[0].rows).first).secondary, FocusPRLabel.noPR)
        XCTAssertEqual(try XCTUnwrap(focusLines(onlyKobeHasAPR[1].rows).first).secondary, "#7 · api")
    }

    func testAnotherHostsPRForTheSameTagIsNotUsed() throws {
        let sections = focusSections(
            hostedFocuses: ["studio": [focus("cody-1")]],
            hostedPerri: ["kobe": HostedPerriState(queue: [],
                                                   currents: ["cody-1": snapshot(repo: "acme/api", number: 7)])])

        XCTAssertEqual(sections.map(\.host.name), ["studio"])
        XCTAssertEqual(try XCTUnwrap(focusLines(sections[0].rows).first).secondary, FocusPRLabel.noPR)
    }

    func testSessionsAreKeptPerSectionByTagSoASameTagSessionNeverCrossesOver() throws {
        let sections = focusSections(
            primaryFocuses: [focus("cody-1")],
            primarySessions: ["cody-1": session("cody-1", state: .midTurn), "only-primary": session("only-primary")],
            hostedFocuses: ["kobe": [focus("cody-1")]],
            hostedSessions: ["kobe": [session("cody-1", state: .awaitingPermission), session("only-kobe")]])

        let primary = try XCTUnwrap(sections.first { $0.host.isPrimary })
        let kobe = try XCTUnwrap(sections.first { $0.host.name == "kobe" })
        XCTAssertEqual(primary.sessions["cody-1"]?.state, .midTurn, "The primary's row shows the primary's session")
        XCTAssertEqual(kobe.sessions["cody-1"]?.state, .awaitingPermission, "Kobe's row shows kobe's session")
        XCTAssertNil(primary.sessions["only-kobe"])
        XCTAssertNil(kobe.sessions["only-primary"])
        XCTAssertNotNil(primary.sessions["only-primary"])
        XCTAssertNotNil(kobe.sessions["only-kobe"])
    }

    func testAnotherHostsSessionsDoNotShowOnASatellitesRow() throws {
        let sections = focusSections(
            hostedFocuses: ["kobe": [focus("cody-1")]],
            hostedSessions: ["studio": [session("cody-1", state: .midTurn)]])

        XCTAssertTrue(try XCTUnwrap(sections.first).sessions.isEmpty)
    }

    // MARK: - Focuses: the Mac's name

    func testASingleHostScopeWithOneSectionHasNoTitle() {
        let sections = focusSections(hostedFocuses: ["kobe": [focus("k1")]], scope: .host("kobe"))
        XCTAssertEqual(sections.count, 1)
        XCTAssertNil(sections[0].title)
    }

    func testTheTitleIsAlwaysSetForAllWorkAndPersonalEvenWithOneSection() {
        let all = focusSections(hostedFocuses: ["kobe": [focus("k1")]], scope: .all)
        XCTAssertEqual(all.map(\.title), ["kobe"])

        let work = focusSections(hostedFocuses: ["kobe": [focus("k1")]], scope: .work)
        XCTAssertEqual(work.map(\.title), ["kobe"])

        let personal = focusSections(primaryFocuses: [focus("p1")], scope: .personal)
        XCTAssertEqual(personal.map(\.title), ["Sendai"])
    }

    func testEverySectionIsTitledWithItsMacsNameWhenSeveralAreShown() {
        let sections = focusSections(primaryFocuses: [focus("p1")], hostedFocuses: ["kobe": [focus("k1")]])
        XCTAssertEqual(sections.map(\.title), ["Sendai", "kobe"])
    }

    // MARK: - Focuses: the real fixtures

    func testTheRealWorkFocusRegistryRendersWithoutAnInventedOrgHeader() throws {
        let list = try focusList("work")

        let sections = focusSections(hostedFocuses: ["kobe": list], scope: .host("kobe"))

        let rows = try XCTUnwrap(sections.first).rows
        XCTAssertFalse(hasOrgHeader(rows), "A host that told us nothing of orgs gets no org header: \(rows)")
        let lines = focusLines(rows)
        XCTAssertEqual(lines.map(\.meta.tag), ["f-33acb7de", "f-48a0007a", "f-70e15afe"],
                       "The built-in first, then the others by agent")
        XCTAssertEqual(lines.map(\.label), ["Perri", "Cody", "Other"])
        XCTAssertTrue(lines.allSatisfy { $0.secondary == FocusPRLabel.noPR })
    }

    func testTheRealPersonalFocusRegistryKeepsItsOrgHeadersAndProjects() throws {
        let list = try focusList("personal")

        let sections = focusSections(hostedFocuses: ["studio": list], scope: .host("studio"))

        let rows = try XCTUnwrap(sections.first).rows
        XCTAssertEqual(rows.map(\.id),
                       ["org:CAREFEED", "focus:cody-1a2b3c4d", "org:PERSONAL", "focus:perri", "focus:claudia-9e8d7c6b"])
        XCTAssertEqual(focusLines(rows).map(\.label), ["Cody in admin-portal", "Perri", "nostromo"])
    }

    func testOneFocusWithAnOrgIsEnoughForTheOrgHeadersToStay() {
        let list = [focus("f-1", agent: "cody"), focus("f-2", agent: "other", org: "Carefeed")]
        let rows = focusSections(hostedFocuses: ["kobe": list], scope: .host("kobe"))[0].rows
        XCTAssertTrue(hasOrgHeader(rows))
    }

    func testOneFocusWithAProjectNameIsEnoughForTheOrgHeadersToStay() {
        let list = [focus("f-1", agent: "cody", project: "admin-portal")]
        let rows = focusSections(hostedFocuses: ["kobe": list], scope: .host("kobe"))[0].rows
        XCTAssertTrue(rows.map(\.id).contains("org:CAREFEED"), "\(rows)")
    }

    func testThePrimarysOwnListKeepsItsOrgHeadersEvenWhenNoneHasAnOrg() {
        // The "no invented header" rule is for a satellite that sent no org information; the primary's
        // list is drawn as it always has been.
        let rows = focusSections(primaryFocuses: [focus("p1", agent: "perri", builtIn: true)])[0].rows
        XCTAssertTrue(hasOrgHeader(rows))
    }

    func testAFocusReviewingAPRShowsItFromTheHostsPerriState() throws {
        let list = try focusList("personal")
        let current = snapshot(repo: "carefeed/admin-portal", number: 4821)

        let sections = focusSections(hostedFocuses: ["studio": list],
                                     hostedPerri: ["studio": HostedPerriState(queue: [],
                                                                              currents: ["cody-1a2b3c4d": current])],
                                     scope: .host("studio"))

        let lines = focusLines(try XCTUnwrap(sections.first).rows)
        XCTAssertEqual(lines.first { $0.meta.tag == "cody-1a2b3c4d" }?.secondary, "#4821 · admin-portal")
        XCTAssertEqual(lines.first { $0.meta.tag == "perri" }?.secondary, FocusPRLabel.noPR)
    }

    // MARK: - Last known

    func testAFocusSectionOfAHostThatIsNotConnectedIsLastKnown() throws {
        let seen = now.addingTimeInterval(-300)
        let hosts = [entry("Sendai", .personal, primary: true),
                     entry("kobe", .work, connected: false, lastSeen: seen),
                     entry("studio", .personal, connected: false, lastSeen: nil)]

        let sections = focusSections(primaryFocuses: [focus("p1")],
                                     hostedFocuses: ["kobe": [focus("k1")], "studio": [focus("s1")]], hosts: hosts)

        let primary = try XCTUnwrap(sections.first { $0.host.isPrimary })
        let kobe = try XCTUnwrap(sections.first { $0.host.name == "kobe" })
        let studio = try XCTUnwrap(sections.first { $0.host.name == "studio" })
        XCTAssertFalse(primary.isLastKnown)
        XCTAssertNil(primary.lastKnownLabel)
        XCTAssertTrue(kobe.isLastKnown)
        XCTAssertTrue(try XCTUnwrap(kobe.lastKnownLabel).hasPrefix("Last seen "))
        XCTAssertTrue(studio.isLastKnown)
        XCTAssertEqual(studio.lastKnownLabel, "Last known")
    }

    // MARK: - Perri: the real work-shaped frame

    func testTheRealWorkPerriStateRendersFromFixedPhrasesWithNoLink() throws {
        let state = try perriState("work")

        let sections = perriSections(["kobe": state], scope: .host("kobe"))

        let section = try XCTUnwrap(sections.first)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(section.rows.map(\.text),
                       ["PR #77 · small change · 3 waiting",
                        "PR #4821 · medium change · 3 waiting",
                        "PR #5 · large change · 3 waiting"],
                       "Size words from changed_lines, three PRs waiting, in bucket order")
        XCTAssertEqual(section.rows.map(\.bucket), ["requested", "needs_review", "dependabot"])
        XCTAssertEqual(section.rows.map(\.secondary), ["r-36a621b5", "r-a9c56c1a", "r-a9c56c1a"],
                       "The repository token is all there is to show")
        XCTAssertTrue(section.rows.allSatisfy { $0.isPseudonymous })
        XCTAssertTrue(section.rows.allSatisfy { $0.url == nil }, "A pseudonymous PR has nowhere to link to")
        XCTAssertEqual(Set(section.rows.map(\.id)).count, 3, "Each row has its own identity")
        XCTAssertTrue(section.rows.allSatisfy { $0.id.hasPrefix("kobe|") })
        XCTAssertTrue(section.rows.allSatisfy { $0.ciState == .unknown })
    }

    func testPerriRowsAreGroupedUnderTheTabsBucketHeadingsInTheTabsOrder() throws {
        let state = try perriState("work")

        let section = try XCTUnwrap(perriSections(["kobe": state], scope: .host("kobe")).first)

        XCTAssertEqual(section.groups.map(\.id), ["requested", "needs_review", "dependabot"])
        XCTAssertEqual(section.groups.map(\.label), ["Requested", "Needs Review", "Dependabot"])
        XCTAssertEqual(section.groups.map { $0.rows.count }, [1, 1, 1])
    }

    func testAllFourBucketsComeInOrderAndAnUnknownBucketComesLastUnderItsOwnHeading() throws {
        let queue = [
            item("acme/web", 9, bucket: "dependabot"),
            item("acme/web", 8, bucket: "mystery"),
            item("acme/web", 7, bucket: "changes_req"),
            item("acme/web", 6, bucket: "needs_review"),
            item("acme/web", 5, bucket: "requested"),
            item("acme/api", 5, bucket: "requested"),
            item("acme/web", 4, bucket: "requested"),
        ]

        let section = try XCTUnwrap(perriSections(onePerriHost(queue), scope: .host("kobe")).first)

        XCTAssertEqual(section.groups.map(\.id), ["requested", "needs_review", "changes_req", "dependabot", "other"])
        XCTAssertEqual(section.groups.map(\.label), ["Requested", "Needs Review", "Changes Req", "Dependabot", "Other"])
        let requested = try XCTUnwrap(section.groups.first)
        XCTAssertEqual(requested.rows.map(\.secondary), ["acme/web", "acme/api", "acme/web"],
                       "Within a bucket: #4 web, then #5 api, then #5 web")
        XCTAssertEqual(section.rows.count, 7)
    }

    func testRowsWithinABucketAreOrderedByNumberThenRepository() throws {
        let queue = [
            item("acme/web", 5, bucket: "requested", title: "web five"),
            item("acme/api", 5, bucket: "requested", title: "api five"),
            item("acme/web", 4, bucket: "requested", title: "web four"),
        ]

        let section = try XCTUnwrap(perriSections(onePerriHost(queue), scope: .host("kobe")).first)

        XCTAssertEqual(section.rows.map(\.text), ["web four", "api five", "web five"])
    }

    func testTheWaitingCountIsEveryUniquePRInTheQueueNotTheBucket() throws {
        let queue = [
            item("acme/web", 1, bucket: "requested", changed: 10),
            item("acme/web", 2, bucket: "needs_review"),
            item("acme/web", 3, bucket: "needs_review", changed: 1_000),
            item("acme/web", 4, bucket: "dependabot", changed: 400),
        ]

        let rows = try XCTUnwrap(perriSections(onePerriHost(queue), scope: .host("kobe")).first).rows

        XCTAssertEqual(rows.map(\.text),
                       ["PR #1 · small change · 4 waiting",
                        "PR #2 · 4 waiting",
                        "PR #3 · large change · 4 waiting",
                        "PR #4 · medium change · 4 waiting"],
                       "No size phrase when the frame carried no size")
    }

    // MARK: - Perri: the real personal frame

    func testTheRealPersonalPerriStateShowsTitlesAuthorsAndLinks() throws {
        let state = try perriState("personal")

        let section = try XCTUnwrap(perriSections(["studio": state], scope: .host("studio")).first)

        XCTAssertEqual(section.rows.map(\.text), ["Fix refund rounding", "Add referral export", "Bump axios"])
        XCTAssertEqual(section.rows.map(\.secondary),
                       ["carefeed/payments · bob", "carefeed/admin-portal · alice",
                        "carefeed/admin-portal · dependabot[bot]"])
        XCTAssertEqual(section.rows.map(\.url),
                       [URL(string: "https://github.com/carefeed/payments/pull/77"),
                        URL(string: "https://github.com/carefeed/admin-portal/pull/4821"),
                        URL(string: "https://github.com/carefeed/admin-portal/pull/5")])
        XCTAssertTrue(section.rows.allSatisfy { !$0.isPseudonymous })
        XCTAssertTrue(section.rows.allSatisfy { $0.ciState == .success })
        XCTAssertEqual(section.groups.map(\.id), ["requested", "needs_review", "dependabot"])
    }

    func testAnEmptyTitleBecomesTheFixedPhraseEvenForAPersonalHostAndATitleIsShownEvenForAPseudonymousRepo() throws {
        let queue = [
            item("acme/web", 1, bucket: "requested", title: "", changed: 12),
            item("r-a9c56c1a", 2, bucket: "needs_review", title: "A real title"),
        ]

        let rows = try XCTUnwrap(perriSections(onePerriHost(queue, host: "studio"), scope: .host("studio")).first).rows

        XCTAssertEqual(rows.map(\.text), ["PR #1 · small change · 2 waiting", "A real title"],
                       "Rendering follows the fields the frame carries, not the host's egress")
    }

    func testTheAuthorIsLeftOutOfTheSecondaryLineWhenThereIsNone() throws {
        let queue = [item("acme/web", 1, title: "t", author: ""), item("acme/web", 2, title: "t", author: "alice")]

        let rows = try XCTUnwrap(perriSections(onePerriHost(queue), scope: .host("kobe")).first).rows

        XCTAssertEqual(rows.map(\.secondary), ["acme/web", "acme/web · alice"])
    }

    func testARowWithNeitherRepositoryNorAuthorHasNoSecondaryLine() throws {
        let queue = [item("", 1, title: "t", author: "")]
        let rows = try XCTUnwrap(perriSections(onePerriHost(queue), scope: .host("kobe")).first).rows
        XCTAssertNil(rows[0].secondary)
    }

    // MARK: - Perri: links

    func testOnlyAnHttpsLinkIsALink() throws {
        let cases: [(url: String, expected: String?)] = [
            ("https://github.com/acme/web/pull/1", "https://github.com/acme/web/pull/1"),
            ("HTTPS://github.com/acme/web/pull/1", "HTTPS://github.com/acme/web/pull/1"),
            ("http://github.com/acme/web/pull/1", nil),
            ("", nil),
            ("javascript:alert(1)", nil),
            ("ftp://github.com/acme/web/pull/1", nil),
            ("github.com/acme/web/pull/1", nil),
            ("file:///etc/passwd", nil),
        ]
        for entry in cases {
            let queue = [item("acme/web", 1, title: "t", url: entry.url)]
            let row = try XCTUnwrap(perriSections(onePerriHost(queue), scope: .host("kobe")).first).rows[0]
            XCTAssertEqual(row.url?.absoluteString, entry.expected, "url \"\(entry.url)\"")
        }
    }

    func testAPseudonymousRepositoryNeverGetsALinkEvenWhenTheFrameCarriesAnHttpsUrl() throws {
        let queue = [item("r-a9c56c1a", 1, title: "t", url: "https://github.com/acme/web/pull/1"),
                     item("r-A9C56C1A", 2, title: "t", url: "https://github.com/acme/web/pull/2")]

        let rows = try XCTUnwrap(perriSections(onePerriHost(queue), scope: .host("kobe")).first).rows

        XCTAssertNil(rows[0].url)
        XCTAssertTrue(rows[0].isPseudonymous)
        XCTAssertNotNil(rows[1].url, "Not exactly the token shape, so it is a repository name like any other")
        XCTAssertFalse(rows[1].isPseudonymous)
    }

    // MARK: - Perri: the token shape

    func testOnlyRDashAndEightLowerCaseHexIsPseudonymous() {
        let cases: [(repo: String, expected: Bool)] = [
            ("r-a9c56c1a", true),
            ("r-00000000", true),
            ("r-ffffffff", true),
            ("r-A9C56C1A", false),
            ("r-a9c56c1", false),
            ("r-a9c56c1ab", false),
            ("r-a9c56c1g", false),
            ("r-a9c56c1 ", false),
            ("r-", false),
            ("R-a9c56c1a", false),
            ("a9c56c1a", false),
            ("x-a9c56c1a", false),
            ("r_a9c56c1a", false),
            ("acme/web", false),
            ("", false),
        ]
        for entry in cases {
            XCTAssertEqual(HostedPerri.isPseudonymousRepo(entry.repo), entry.expected, "repo \"\(entry.repo)\"")
        }
    }

    // MARK: - Perri: duplicates

    func testADuplicateOfTheSameRepoNumberAndBucketCollapsesToOneRow() throws {
        let queue = [item("acme/web", 1, bucket: "requested", title: ""),
                     item("acme/web", 1, bucket: "requested", title: ""),
                     item("acme/web", 2, bucket: "requested", title: "")]

        let rows = try XCTUnwrap(perriSections(onePerriHost(queue), scope: .host("kobe")).first).rows

        XCTAssertEqual(rows.map(\.text), ["PR #1 · 2 waiting", "PR #2 · 2 waiting"],
                       "One row for the duplicate, and the count is of distinct PRs")
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testTheSamePRInTwoBucketsOrTheSameNumberInTwoReposStaysSeparate() throws {
        let queue = [item("acme/web", 1, bucket: "requested", title: "a"),
                     item("acme/web", 1, bucket: "needs_review", title: "b"),
                     item("acme/api", 1, bucket: "requested", title: "c")]

        let rows = try XCTUnwrap(perriSections(onePerriHost(queue), scope: .host("kobe")).first).rows

        XCTAssertEqual(Set(rows.map(\.text)), ["a", "b", "c"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3, "Distinct identities, so a list can show all three")
    }

    // MARK: - Perri: who is listed

    func testThePrimarysPerriStateIsNotPartOfTheHostedSections() {
        let sections = perriSections(["Sendai": HostedPerriState(queue: [item("acme/web", 1, title: "t")], currents: [:]),
                                      "kobe": HostedPerriState(queue: [item("acme/web", 2, title: "t")], currents: [:])])

        XCTAssertEqual(sections.map(\.host.name), ["kobe"], "The Perri tab draws the primary's own queue itself")
    }

    func testTheScopeNarrowsThePerriSections() {
        let queue = [item("acme/web", 1, title: "t")]
        let all = ["kobe": HostedPerriState(queue: queue, currents: [:]),
                   "studio": HostedPerriState(queue: queue, currents: [:])]
        XCTAssertEqual(perriSections(all, scope: .all).map(\.host.name), ["kobe", "studio"])
        XCTAssertEqual(perriSections(all, scope: .work).map(\.host.name), ["kobe"])
        XCTAssertEqual(perriSections(all, scope: .personal).map(\.host.name), ["studio"])
        XCTAssertEqual(perriSections(all, scope: .host("studio")).map(\.host.name), ["studio"])
        XCTAssertEqual(perriSections(all, scope: .host("Sendai")).map(\.host.name), [])
        XCTAssertEqual(perriSections(all, scope: .host("nobody")).map(\.host.name), [])
    }

    func testAHostWithNoRowsHasNoPerriSection() {
        let sections = perriSections([
            "kobe": HostedPerriState(queue: [], currents: ["f-1": snapshot(repo: "acme/web", number: 1)]),
            "studio": HostedPerriState(queue: [item("acme/web", 1, title: "t")], currents: [:]),
        ])
        XCTAssertEqual(sections.map(\.host.name), ["studio"], "A current PR alone is not a queue row")
    }

    func testAHostWithQueueRowsButNoEntryInHostsHasNoPerriSection() {
        XCTAssertTrue(perriSections(onePerriHost([item("acme/web", 1, title: "t")], host: "ghost")).isEmpty)
    }

    // MARK: - Perri: the Mac's name

    func testAPerriSectionIsTitledUnlessTheScopeIsOneMacAndOnlyOneMacShowsRows() {
        let queue = [item("acme/web", 1, title: "t")]
        let one = onePerriHost(queue)
        let two = ["kobe": HostedPerriState(queue: queue, currents: [:]),
                   "studio": HostedPerriState(queue: queue, currents: [:])]

        XCTAssertEqual(perriSections(one, scope: .host("kobe")).map(\.title), [nil])
        XCTAssertEqual(perriSections(one, scope: .all).map(\.title), ["kobe"], "All always names the Mac")
        XCTAssertEqual(perriSections(one, scope: .work).map(\.title), ["kobe"], "Work always names the Mac")
        XCTAssertEqual(perriSections(two, scope: .all).map(\.title), ["kobe", "studio"])
        XCTAssertEqual(perriSections(one, scope: .host("kobe"), includePrimary: true).map(\.title), ["kobe"],
                       "The primary's queue is drawn beside it, so two Macs show rows")
    }

    func testAPerriSectionOfAHostThatIsNotConnectedIsLastKnown() throws {
        let queue = [item("acme/web", 1, title: "t")]
        let hosts = [entry("Sendai", .personal, primary: true),
                     entry("kobe", .work, connected: false, lastSeen: now.addingTimeInterval(-120)),
                     entry("studio", .personal, connected: true)]

        let sections = perriSections(["kobe": HostedPerriState(queue: queue, currents: [:]),
                                      "studio": HostedPerriState(queue: queue, currents: [:])], hosts: hosts)

        let kobe = try XCTUnwrap(sections.first { $0.host.name == "kobe" })
        let studio = try XCTUnwrap(sections.first { $0.host.name == "studio" })
        XCTAssertTrue(kobe.isLastKnown)
        XCTAssertTrue(try XCTUnwrap(kobe.lastKnownLabel).hasPrefix("Last seen "))
        XCTAssertFalse(studio.isLastKnown)
        XCTAssertNil(studio.lastKnownLabel)
    }
}
