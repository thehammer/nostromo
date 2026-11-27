// NostromoKit — HostedFrameGoldenTests.swift
//
// The frames a paired phone really receives from a satellite host, decoded (W11 slice 2). The
// fixtures in `tests/fixtures/hosts/` were captured from the Rust daemon's own redaction output, so
// they are the ground truth of the wire: if the daemon's redaction changes, its tests fail first and
// these follow.
//
//   * `<name>.work.json`     host "kobe": a work host, metadata only (pseudonymous `f-xxxxxxxx` tags,
//                            `r-xxxxxxxx` repositories, empty titles, authors, URLs and prompts);
//   * `<name>.personal.json` host "studio": a personal host (real names, titles, links, prompts).
//
// What these guard: the host a frame names, the variant it decodes to, and every field the screens
// read; and that a work-shaped frame goes through exactly the code a personal one does (the decoder
// has no egress branch, so a host's profile changing needs no phone change).

import XCTest
@testable import NostromoKit

final class HostedFrameGoldenTests: XCTestCase {

    // MARK: - Fixtures

    private enum FixtureProblem: Error { case missing, wrongShape }

    private func fixtureData(_ name: String, _ kind: String) throws -> Data {
        var url = URL(fileURLWithPath: "\(#filePath)")
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("tests/fixtures/hosts/\(name).\(kind).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("fixture not found at \(url.path)")
            throw FixtureProblem.missing
        }
        return try Data(contentsOf: url)
    }

    private func hosted(_ name: String, _ kind: String) throws -> HostedServerMsg {
        let data = try fixtureData(name, kind)
        let result = ServerMsg.decodeHosted(from: data)
        XCTAssertEqual(result.raw, data, "decodeHosted keeps the frame as it arrived, for the cache")
        return result
    }

    private func perri(_ kind: String) throws -> (host: String?, tag: String, queue: [PrQueueItem], current: PrSnapshot?) {
        let frame = try hosted("perri_state", kind)
        guard case let .perriState(tag, queue, current) = frame.msg else {
            XCTFail("perri_state.\(kind).json decoded as \(frame.msg)")
            throw FixtureProblem.wrongShape
        }
        return (frame.host, tag, queue, current)
    }

    private func registry(_ kind: String) throws -> (host: String?, focuses: [FocusMeta]) {
        let frame = try hosted("focus_registry_updated", kind)
        guard case let .focusRegistryUpdated(list) = frame.msg else {
            XCTFail("focus_registry_updated.\(kind).json decoded as \(frame.msg)")
            throw FixtureProblem.wrongShape
        }
        return (frame.host, list)
    }

    private func request(_ kind: String) throws
        -> (host: String?, tag: String, requestId: String, prompt: String, detail: String?, choices: [DecisionChoice]) {
        let frame = try hosted("decision_request", kind)
        guard case let .decisionRequest(tag, requestId, prompt, detail, choices, _) = frame.msg else {
            XCTFail("decision_request.\(kind).json decoded as \(frame.msg)")
            throw FixtureProblem.wrongShape
        }
        return (frame.host, tag, requestId, prompt, detail, choices)
    }

    private func resolved(_ kind: String) throws
        -> (host: String?, tag: String, requestId: String, resolution: String, choiceId: String?) {
        let frame = try hosted("decision_resolved", kind)
        guard case let .decisionResolved(tag, requestId, resolution, choiceId) = frame.msg else {
            XCTFail("decision_resolved.\(kind).json decoded as \(frame.msg)")
            throw FixtureProblem.wrongShape
        }
        return (frame.host, tag, requestId, resolution, choiceId)
    }

    private func approval(_ kind: String) throws -> (host: String?, tag: String, count: Int) {
        let frame = try hosted("approval_pending", kind)
        guard case let .approvalPending(tag, count) = frame.msg else {
            XCTFail("approval_pending.\(kind).json decoded as \(frame.msg)")
            throw FixtureProblem.wrongShape
        }
        return (frame.host, tag, count)
    }

    private func isFocusToken(_ tag: String) -> Bool {
        tag.hasPrefix("f-") && tag.dropFirst(2).count == 8 && tag.dropFirst(2).allSatisfy { "0123456789abcdef".contains($0) }
    }

    // MARK: - perri_state

    func testTheWorkPerriStateIsKobesMetadataOnlyQueue() throws {
        let frame = try perri("work")

        XCTAssertEqual(frame.host, "kobe")
        XCTAssertEqual(frame.tag, "f-33acb7de")
        XCTAssertNil(frame.current)
        XCTAssertEqual(frame.queue.count, 3)
        XCTAssertEqual(frame.queue.map(\.repo), ["r-a9c56c1a", "r-36a621b5", "r-a9c56c1a"])
        XCTAssertEqual(frame.queue.map(\.number), [4821, 77, 5])
        XCTAssertEqual(frame.queue.map(\.changedLines), [120, 12, 480])
        XCTAssertEqual(frame.queue.map(\.bucket), ["needs_review", "requested", "dependabot"])
        XCTAssertEqual(frame.queue.map(\.title), ["", "", ""])
        XCTAssertEqual(frame.queue.map(\.author), ["", "", ""])
        XCTAssertEqual(frame.queue.map(\.url), ["", "", ""])
        XCTAssertEqual(frame.queue.map(\.headSha), ["", "", ""])
        XCTAssertEqual(frame.queue.map(\.ciState), [.unknown, .unknown, .unknown])
        XCTAssertEqual(frame.queue.map(\.isBot), [false, false, false])
        XCTAssertEqual(frame.queue.map(\.newActivity), [false, false, false])
    }

    func testThePersonalPerriStateIsStudiosQueueWithRealRows() throws {
        let frame = try perri("personal")

        XCTAssertEqual(frame.host, "studio")
        XCTAssertEqual(frame.tag, "perri")
        XCTAssertNil(frame.current)
        XCTAssertEqual(frame.queue.map(\.repo), ["carefeed/admin-portal", "carefeed/payments", "carefeed/admin-portal"])
        XCTAssertEqual(frame.queue.map(\.number), [4821, 77, 5])
        XCTAssertEqual(frame.queue.map(\.title), ["Add referral export", "Fix refund rounding", "Bump axios"])
        XCTAssertEqual(frame.queue.map(\.author), ["alice", "bob", "dependabot[bot]"])
        XCTAssertEqual(frame.queue.map(\.url),
                       ["https://github.com/carefeed/admin-portal/pull/4821",
                        "https://github.com/carefeed/payments/pull/77",
                        "https://github.com/carefeed/admin-portal/pull/5"])
        XCTAssertEqual(frame.queue.map(\.ciState), [.success, .success, .success])
        XCTAssertEqual(frame.queue.map(\.isBot), [false, false, true], "Only the dependabot row is a bot")
        XCTAssertEqual(frame.queue.map(\.bucket), ["needs_review", "requested", "dependabot"])
        XCTAssertEqual(frame.queue.map(\.changedLines), [120, 12, 480])
        XCTAssertEqual(frame.queue.map(\.headSha), ["9f1c2ab", "9f1c2ab", "9f1c2ab"])
    }

    // MARK: - focus_registry_updated

    func testTheWorkFocusRegistryHasThreePseudonymousFocusesAndNoOrgOrProject() throws {
        let frame = try registry("work")

        XCTAssertEqual(frame.host, "kobe")
        XCTAssertEqual(frame.focuses.map(\.tag), ["f-33acb7de", "f-48a0007a", "f-70e15afe"])
        XCTAssertTrue(frame.focuses.allSatisfy { isFocusToken($0.tag) }, "\(frame.focuses.map(\.tag))")
        XCTAssertEqual(frame.focuses.map(\.agentName), ["perri", "cody", "other"])
        XCTAssertEqual(frame.focuses.map(\.displayName), frame.focuses.map(\.agentName),
                       "A work host's display name is just the agent name")
        XCTAssertEqual(frame.focuses.map(\.isBuiltIn), [true, false, false])
        XCTAssertTrue(frame.focuses.allSatisfy { $0.org == nil })
        XCTAssertTrue(frame.focuses.allSatisfy { $0.projectName == nil })
        XCTAssertTrue(frame.focuses.allSatisfy { $0.sessionSummary == nil })
    }

    func testThePersonalFocusRegistryCarriesOrgsProjectsAndDisplayNames() throws {
        let frame = try registry("personal")

        XCTAssertEqual(frame.host, "studio")
        XCTAssertEqual(frame.focuses.map(\.tag), ["perri", "cody-1a2b3c4d", "claudia-9e8d7c6b"])
        XCTAssertEqual(frame.focuses.map(\.agentName), ["perri", "cody", "claudia"])
        XCTAssertEqual(frame.focuses.map(\.displayName), ["Perri", "Cody", "Claudia"])
        XCTAssertEqual(frame.focuses.map(\.org), [nil, "Carefeed", "Personal"])
        XCTAssertEqual(frame.focuses.map(\.projectName), [nil, "admin-portal", "nostromo"])
        XCTAssertEqual(frame.focuses.map(\.isBuiltIn), [true, false, false])
    }

    // MARK: - decision_request

    func testTheWorkDecisionRequestHasNoPromptAndUnlabelledChoices() throws {
        let frame = try request("work")

        XCTAssertEqual(frame.host, "kobe")
        XCTAssertEqual(frame.tag, "f-48a0007a")
        XCTAssertEqual(frame.requestId, "req-0a1b2c3d")
        XCTAssertEqual(frame.prompt, "")
        XCTAssertNil(frame.detail)
        XCTAssertEqual(frame.choices.map(\.id), ["c0", "c1"])
        XCTAssertEqual(frame.choices.map(\.label), ["", ""])
    }

    func testThePersonalDecisionRequestCarriesItsQuestionAndChoices() throws {
        let frame = try request("personal")

        XCTAssertEqual(frame.host, "studio")
        XCTAssertEqual(frame.tag, "cody-1a2b3c4d")
        XCTAssertEqual(frame.requestId, "req-0a1b2c3d")
        XCTAssertEqual(frame.prompt, "Ship the export behind a flag?")
        XCTAssertEqual(frame.detail, "Touches billing.")
        XCTAssertEqual(frame.choices.map(\.id), ["yes", "no"])
        XCTAssertEqual(frame.choices.map(\.label), ["Yes, behind a flag", "Not yet"])
    }

    // MARK: - decision_resolved

    func testTheResolvedFramesNameTheirHostAndTheRequestTheyResolve() throws {
        let work = try resolved("work")
        XCTAssertEqual(work.host, "kobe")
        XCTAssertEqual(work.tag, "f-48a0007a")
        XCTAssertEqual(work.requestId, "req-0a1b2c3d")
        XCTAssertEqual(work.resolution, "answered")
        XCTAssertNil(work.choiceId, "A work host does not say which choice")

        let personal = try resolved("personal")
        XCTAssertEqual(personal.host, "studio")
        XCTAssertEqual(personal.tag, "cody-1a2b3c4d")
        XCTAssertEqual(personal.requestId, "req-0a1b2c3d")
        XCTAssertEqual(personal.resolution, "answered")
        XCTAssertEqual(personal.choiceId, "yes")
    }

    // MARK: - approval_pending

    func testTheApprovalFramesCarryOnlyATagAndACount() throws {
        let work = try approval("work")
        XCTAssertEqual(work.host, "kobe")
        XCTAssertEqual(work.tag, "f-48a0007a")
        XCTAssertEqual(work.count, 2)

        let personal = try approval("personal")
        XCTAssertEqual(personal.host, "studio")
        XCTAssertEqual(personal.tag, "cody-1a2b3c4d")
        XCTAssertEqual(personal.count, 2)
    }

    // MARK: - One code path

    private func renamed(_ data: Data, to host: String) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["host"] = host
        return try JSONSerialization.data(withJSONObject: object)
    }

    func testAWorkShapedFrameDecodesIdenticallyWhicheverHostNameItNames() throws {
        // The decoder has no egress branch: only the host name differs between the two reads, and the
        // payload comes out the same. (If decoding depended on what kind of host it was, a work
        // frame under a personal host's name would come out differently.)
        let work = try fixtureData("perri_state", "work")
        guard case let .perriState(_, asKobe, _) = ServerMsg.decodeHosted(from: work).msg,
              case let .perriState(_, asStudio, _) = ServerMsg.decodeHosted(from: try renamed(work, to: "studio")).msg
        else { return XCTFail("perri_state did not decode") }
        XCTAssertEqual(ServerMsg.decodeHosted(from: try renamed(work, to: "studio")).host, "studio")
        XCTAssertEqual(asKobe, asStudio)
        XCTAssertEqual(asStudio.count, 3)

        let personal = try fixtureData("perri_state", "personal")
        guard case let .perriState(_, asStudioAgain, _) = ServerMsg.decodeHosted(from: personal).msg,
              case let .perriState(_, asKobeAgain, _) = ServerMsg.decodeHosted(from: try renamed(personal, to: "kobe")).msg
        else { return XCTFail("perri_state did not decode") }
        XCTAssertEqual(asStudioAgain, asKobeAgain)
        XCTAssertEqual(asKobeAgain.map(\.title), ["Add referral export", "Fix refund rounding", "Bump axios"],
                       "A personal frame under a work host's name keeps its titles")
    }

    func testEveryFixtureDecodesToItsOwnVariantNotUnknown() throws {
        let expectations: [(name: String, check: (ServerMsg) -> Bool)] = [
            ("perri_state", { if case .perriState = $0 { return true } else { return false } }),
            ("focus_registry_updated", { if case .focusRegistryUpdated = $0 { return true } else { return false } }),
            ("decision_request", { if case .decisionRequest = $0 { return true } else { return false } }),
            ("decision_resolved", { if case .decisionResolved = $0 { return true } else { return false } }),
            ("approval_pending", { if case .approvalPending = $0 { return true } else { return false } }),
        ]
        for expectation in expectations {
            for kind in ["work", "personal"] {
                let frame = try hosted(expectation.name, kind)
                XCTAssertNotNil(frame.host, "\(expectation.name).\(kind) names its host")
                XCTAssertTrue(expectation.check(frame.msg), "\(expectation.name).\(kind) decoded as \(frame.msg)")
            }
        }
    }

    func testAFrameWithNoHostIsThePrimarysOwn() throws {
        let work = try fixtureData("approval_pending", "work")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: work) as? [String: Any])
        object.removeValue(forKey: "host")

        let frame = ServerMsg.decodeHosted(from: try JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(frame.host)
        guard case let .approvalPending(tag, count) = frame.msg else { return XCTFail("expected approvalPending") }
        XCTAssertEqual(tag, "f-48a0007a")
        XCTAssertEqual(count, 2)
    }

    // MARK: - changed_lines

    private func item(_ extra: String) -> PrQueueItem? {
        let json = #"{"repo":"acme/web","number":1,"title":"t","author":"a","bucket":"requested","url":"https://github.com/acme/web/pull/1"\#(extra)}"#
        return try? JSONDecoder().decode(PrQueueItem.self, from: Data(json.utf8))
    }

    func testChangedLinesIsNilForARowWithoutTheKey() throws {
        let row = try XCTUnwrap(item(""))
        XCTAssertNil(row.changedLines, "Absent means unknown, not zero")
    }

    func testChangedLinesIsReadWhenPresentIncludingZero() throws {
        XCTAssertEqual(try XCTUnwrap(item(#","changed_lines":120"#)).changedLines, 120)
        XCTAssertEqual(try XCTUnwrap(item(#","changed_lines":0"#)).changedLines, 0)
    }

    func testAChangedLinesValueOfTheWrongTypeIsUnknownAndNeverCostsTheRow() throws {
        let row = try XCTUnwrap(item(#","changed_lines":"many""#))
        XCTAssertNil(row.changedLines)
        XCTAssertEqual(row.number, 1)
    }

    func testAPerriStateWithOneRowMissingChangedLinesStillDecodesTheOthers() throws {
        let json = """
        {"type":"perri_state","host":"kobe","tag":"f-33acb7de","current":null,"queue":[
          {"repo":"r-a9c56c1a","number":1,"title":"","author":"","bucket":"requested","url":"","changed_lines":30},
          {"repo":"r-a9c56c1a","number":2,"title":"","author":"","bucket":"requested","url":""}
        ]}
        """
        guard case let .perriState(_, queue, _) = ServerMsg.decodeHosted(from: Data(json.utf8)).msg else {
            return XCTFail("expected perriState")
        }
        XCTAssertEqual(queue.map(\.number), [1, 2])
        XCTAssertEqual(queue.map(\.changedLines), [30, nil])
    }
}
