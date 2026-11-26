// NostromoKit — SeqWireTests.swift
//
// W12: per-topic sequence numbers, `Gap`, and the client's `SeqTracker` (pure: no socket).

import XCTest
@testable import NostromoKit

final class SeqWireTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    // MARK: topic and number

    func testANumberedTopicFrameYieldsItsTopicAndSeq() {
        let frame = data(#"{"type":"perri_state","tag":"perri","queue":[],"seq":12}"#)
        let got = SeqWire.topicSeq(from: frame)
        XCTAssertEqual(got?.topic, "perri")
        XCTAssertEqual(got?.seq, 12)
    }

    func testActivityFramesCarryTheirTopicNumberInTopicSeqNotTheStreamSeq() {
        let frame = data(#"{"type":"activity","kind":"tool_use","seq":3,"topic_seq":41}"#)
        XCTAssertEqual(SeqWire.topicSeq(from: frame)?.seq, 41, "the stream's own seq is not the topic's")
        XCTAssertEqual(SeqWire.topicSeq(from: frame)?.topic, "activity")
        let onlyStream = data(#"{"type":"activity","kind":"tool_use","seq":3}"#)
        XCTAssertNil(SeqWire.topicSeq(from: onlyStream), "no topic number: the stream's counter must not be read as one")
    }

    func testAFrameWithNoTopicHasNoNumberWhateverKeysItHas() {
        XCTAssertNil(SeqWire.topicSeq(from: data(#"{"type":"session_state","tag":"a","state":"idle","seq":9}"#)))
        XCTAssertNil(SeqWire.topicSeq(from: data(#"{"type":"hosts","hosts":[]}"#)))
        XCTAssertNil(SeqWire.topicSeq(from: data("not json")))
    }

    func testATopicFrameWithoutANumberIsNotNumbered() {
        XCTAssertNil(SeqWire.topicSeq(from: data(#"{"type":"mother_jobs","jobs":[]}"#)))
    }

    // MARK: gap

    func testAGapDecodesItsBoundsTopicAndReason() {
        let msg = ServerMsg.decode(from: data(
            #"{"type":"gap","topic":"mother_jobs","from":5,"to":9,"reason":"client_slow"}"#))
        guard case .gap(let topic, let host, let from, let to, let reason) = msg else {
            return XCTFail("not a gap: \(msg)")
        }
        XCTAssertEqual(topic, "mother_jobs")
        XCTAssertNil(host)
        XCTAssertEqual(from, 5)
        XCTAssertEqual(to, 9)
        XCTAssertEqual(reason, .clientSlow)
    }

    func testEveryGapReasonAndAnUnknownOneDecode() {
        for (wire, reason) in [("replay_window_exceeded", GapReason.replayWindowExceeded),
                               ("client_slow", .clientSlow), ("uplink_reconnect", .uplinkReconnect),
                               ("daemon_restarted", .daemonRestarted), ("lagged", .lagged),
                               ("something_new", .unknown)] {
            let msg = ServerMsg.decode(from: data(
                #"{"type":"gap","topic":"perri","host":"kobe","from":1,"to":2,"reason":"\#(wire)"}"#))
            guard case .gap(_, let host, _, _, let got) = msg else { return XCTFail("not a gap") }
            XCTAssertEqual(got, reason, wire)
            XCTAssertEqual(host, "kobe")
        }
    }

    /// `numberJump` is the client's own and has no wire string: a daemon that sent one would be
    /// read as an unknown reason, never as the client-made one.
    func testNoWireStringDecodesAsTheClientMadeNumberJump() {
        XCTAssertEqual(GapReason(wire: "number_jump"), .unknown)
        XCTAssertEqual(GapReason(wire: nil), .unknown)
    }

    func testOnlyADaemonRestartIsNotAReasonToWarnOfMissedUpdates() {
        XCTAssertFalse(GapReason.daemonRestarted.mayHaveMissedUpdates, "its snapshots replaced the list")
        for reason in [GapReason.replayWindowExceeded, .clientSlow, .uplinkReconnect, .lagged, .numberJump, .unknown] {
            XCTAssertTrue(reason.mayHaveMissedUpdates, "\(reason) may have left the list stale")
        }
    }

    func testAGapMissingItsBoundsIsUnknownNotACrash() {
        guard case .unknown = ServerMsg.decode(from: data(#"{"type":"gap","topic":"perri"}"#)) else {
            return XCTFail("a malformed gap must decode as unknown")
        }
    }

    // MARK: tracker

    func testTheTrackerKeepsTheHighestNumberPerTopic() {
        var t = SeqTracker()
        XCTAssertTrue(t.resume.isEmpty)
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":4}"#))
        t.observe(data(#"{"type":"mother_jobs","jobs":[],"seq":2}"#))
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":3}"#))   // late: does not lower it
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":5}"#))
        XCTAssertEqual(t.resume, ["perri": 5, "mother_jobs": 2])
    }

    func testFramesWithNoTopicLeaveTheTrackerAlone() {
        var t = SeqTracker()
        t.observe(data(#"{"type":"session_state","tag":"a","seq":50}"#))
        t.observe(data(#"{"type":"pong"}"#))
        XCTAssertTrue(t.resume.isEmpty)
    }

    func testAReplayWindowGapSetsTheNumberSoARestartedDaemonIsFollowed() {
        var t = SeqTracker()
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":500}"#))
        // The daemon restarted: its numbers start again, and it says so.
        t.observe(data(#"{"type":"gap","topic":"perri","from":1,"to":3,"reason":"replay_window_exceeded"}"#))
        XCTAssertEqual(t.resume, ["perri": 3])
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":4}"#))
        XCTAssertEqual(t.resume, ["perri": 4])
    }

    func testASlowClientGapNeverLowersTheNumber() {
        var t = SeqTracker()
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":20}"#))
        t.observe(data(#"{"type":"gap","topic":"perri","from":10,"to":15,"reason":"client_slow"}"#))
        XCTAssertEqual(t.resume["perri"], 20)
        t.observe(data(#"{"type":"gap","topic":"perri","from":21,"to":30,"reason":"client_slow"}"#))
        XCTAssertEqual(t.resume["perri"], 30)
    }

    func testResetForgetsEverything() {
        var t = SeqTracker()
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":4}"#))
        t.reset()
        XCTAssertTrue(t.resume.isEmpty)
    }

    // MARK: tracker: daemon restart (epoch)

    private func welcome(epoch: UInt64?) -> Data {
        let epochKey = epoch.map { #","seq_epoch":\#($0)"# } ?? ""
        return data(#"{"type":"welcome","protocol_version":4,"daemon_pid":1,"features":["seq"]\#(epochKey)}"#)
    }

    func testAWelcomeFromAnotherDaemonRunDropsTheNumbersAndSaysSo() {
        var t = SeqTracker()
        XCTAssertEqual(t.observe(welcome(epoch: 1)), .none, "the first epoch seen is just remembered")
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":40}"#))
        t.observe(data(#"{"type":"mother_jobs","jobs":[],"seq":7}"#))
        XCTAssertEqual(t.resume, ["perri": 40, "mother_jobs": 7])

        XCTAssertEqual(t.observe(welcome(epoch: 2)), .epochChanged)
        XCTAssertTrue(t.resume.isEmpty, "a restarted daemon numbers from 1: the old numbers mean nothing")
        XCTAssertEqual(t.epoch, 2)

        // The new run's numbers are followed from the start, and its epoch is the one now held.
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":1}"#))
        XCTAssertEqual(t.resume, ["perri": 1])
        XCTAssertEqual(t.observe(welcome(epoch: 2)), .none)
        XCTAssertEqual(t.resume, ["perri": 1])
    }

    func testAWelcomeFromTheSameDaemonRunKeepsTheNumbers() {
        var t = SeqTracker()
        t.observe(welcome(epoch: 1))
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":40}"#))
        XCTAssertEqual(t.observe(welcome(epoch: 1)), .none)
        XCTAssertEqual(t.resume, ["perri": 40])
        XCTAssertEqual(t.epoch, 1)
    }

    func testAWelcomeWithoutAnEpochLeavesTheNumbersAndTheHeldEpochAlone() {
        var t = SeqTracker()
        t.observe(welcome(epoch: 1))
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":40}"#))
        XCTAssertEqual(t.observe(welcome(epoch: nil)), .none, "a daemon that predates the epoch says nothing")
        XCTAssertEqual(t.resume, ["perri": 40])
        XCTAssertEqual(t.epoch, 1)
        XCTAssertEqual(t.observe(welcome(epoch: 2)), .epochChanged, "the epoch held is still the last one named")
    }

    func testResetForgetsTheEpochToo() {
        var t = SeqTracker()
        t.observe(welcome(epoch: 1))
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":4}"#))
        t.reset()
        XCTAssertTrue(t.resume.isEmpty)
        XCTAssertNil(t.epoch)
        XCTAssertEqual(t.observe(welcome(epoch: 2)), .none, "nothing is held, so nothing changed")
        XCTAssertEqual(t.epoch, 2)
    }

    func testADaemonRestartedGapSetsTheNumberEvenWhenItLowersIt() {
        var t = SeqTracker()
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":500}"#))
        XCTAssertEqual(t.observe(data(#"{"type":"gap","topic":"perri","from":1,"to":3,"reason":"daemon_restarted"}"#)), .none)
        XCTAssertEqual(t.resume, ["perri": 3])
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":4}"#))
        XCTAssertEqual(t.resume, ["perri": 4])
    }

    func testADaemonRestartedGapFromZeroToZeroSetsTheNumberToZero() {
        var t = SeqTracker()
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":500}"#))
        t.observe(data(#"{"type":"gap","topic":"perri","from":0,"to":0,"reason":"daemon_restarted"}"#))
        XCTAssertEqual(t.resume["perri"], 0, "a topic the new run has not numbered yet starts from nothing")
        t.observe(data(#"{"type":"perri_state","tag":"p","seq":1}"#))
        XCTAssertEqual(t.resume["perri"], 1)
    }

    // MARK: tracker: a skipped number

    private func focuses(_ seq: Int) -> Data {
        data(#"{"type":"focus_registry_updated","focuses":[],"seq":\#(seq)}"#)
    }

    func testASkippedNumberOnAContiguousTopicIsAJumpNamingTheMissingRange() {
        var t = SeqTracker()
        XCTAssertEqual(t.observe(focuses(3)), .none)
        XCTAssertEqual(t.observe(focuses(5)), .jumped(topic: "focuses", from: 4, to: 4))
        XCTAssertEqual(t.resume["focuses"], 5, "the frame itself is still folded in")
        XCTAssertEqual(t.observe(focuses(6)), .none)

        XCTAssertEqual(t.observe(data(#"{"type":"mother_statusline","seq":1}"#)), .none)
        XCTAssertEqual(t.observe(data(#"{"type":"mother_statusline","seq":4}"#)),
                       .jumped(topic: "mother_statusline", from: 2, to: 3))
    }

    func testASkippedNumberOnATopicWhereNumbersLegitimatelySkipIsNotAJump() {
        var t = SeqTracker()
        XCTAssertEqual(t.observe(data(#"{"type":"mother_jobs","jobs":[],"seq":1}"#)), .none)
        XCTAssertEqual(t.observe(data(#"{"type":"mother_jobs","jobs":[],"seq":3}"#)), .none)
        XCTAssertEqual(t.observe(data(#"{"type":"perri_state","tag":"p","seq":2}"#)), .none)
        XCTAssertEqual(t.observe(data(#"{"type":"perri_state","tag":"p","seq":9}"#)), .none)
    }

    func testTheFirstFrameOfATopicIsNeverAJumpHoweverHighItsNumber() {
        var t = SeqTracker()
        XCTAssertEqual(t.observe(focuses(57)), .none, "the client joined late; nothing before it was expected")
    }

    func testARepeatedOrLateNumberIsNotAJump() {
        var t = SeqTracker()
        t.observe(focuses(5))
        XCTAssertEqual(t.observe(focuses(5)), .none)
        XCTAssertEqual(t.observe(focuses(3)), .none)
        XCTAssertEqual(t.resume["focuses"], 5)
    }

    func testANamedGapInBetweenMeansTheNextNumberIsNotAJump() {
        var t = SeqTracker()
        t.observe(focuses(3))
        t.observe(data(#"{"type":"gap","topic":"focuses","from":4,"to":4,"reason":"client_slow"}"#))
        XCTAssertEqual(t.observe(focuses(5)), .none, "the daemon said what was lost")
    }

    func testTheContiguousTopicsAreTheOnesNoFrameIsWithheldFrom() {
        XCTAssertEqual(SeqWire.contiguousTopics, ["focuses", "mother_statusline"])
    }

    // MARK: the topic table is the daemon's

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NostromoKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NostromoKit
        .deletingLastPathComponent()   // Shared
        .deletingLastPathComponent()   // <repo>

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private func snakeCase(_ camel: String) -> String {
        var out = ""
        for (i, ch) in camel.enumerated() {
            if ch.isUppercase, i > 0 { out.append("_") }
            out.append(contentsOf: ch.lowercased())
        }
        return out
    }

    /// The body (between the outermost braces) of the first `needle` function in `text`.
    private func body(ofFunctionStartingWith needle: String, in text: String) -> String? {
        guard let start = text.range(of: needle),
              let open = text[start.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = open
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[text.index(after: open)..<index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private func matches(_ pattern: String, in text: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let whole = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: whole).map { m in
            (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    /// `ServerMsg::topic()` in the daemon, as (wire type, topic) pairs.
    private func daemonTopicTable() throws -> [String: String] {
        let rust = try source("src/ipc/protocol.rs")
        let attrs = try XCTUnwrap(matches(#"((?:#\[[^\n]*\]\n|///[^\n]*\n)*)pub enum ServerMsg "#, in: rust).first?[1],
                                  "the ServerMsg enum is gone from src/ipc/protocol.rs: update this test's parser")
        XCTAssertTrue(attrs.contains(#"rename_all = "snake_case""#),
                      "ServerMsg's wire names are no longer snake_case of the variant: update snakeCase()")
        let fn = try XCTUnwrap(
            body(ofFunctionStartingWith: "pub fn topic(&self) -> Option<Topic>", in: rust),
            "ServerMsg::topic() was not found in src/ipc/protocol.rs: update this test's parser")
        let code = fn.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let arms = matches(#"((?:ServerMsg::\w+\s*(?:\{[^}]*\}|\([^)]*\))?\s*\|?\s*)+)=>\s*Some\(Topic::(\w+)\)"#, in: code)
        var table: [String: String] = [:]
        for arm in arms {
            for variant in matches(#"ServerMsg::(\w+)"#, in: arm[1]) {
                table[snakeCase(variant[1])] = snakeCase(arm[2])
            }
        }
        XCTAssertGreaterThanOrEqual(table.count, 20,
                                    "parsed only \(table.count) arms of ServerMsg::topic(): update this test's parser")
        return table
    }

    /// Every wire type the Kit's own table (`SeqWire.topic(ofFrameType:)`) names: the string
    /// literals of its `case` lines, read from the source because the table is a `switch`.
    private func kitFrameTypes() throws -> [String] {
        let swift = try source("Shared/NostromoKit/Sources/NostromoKit/Wire/SeqWire.swift")
        let fn = try XCTUnwrap(body(ofFunctionStartingWith: "static func topic(ofFrameType", in: swift),
                               "SeqWire.topic(ofFrameType:) was not found: update this test's parser")
        let types = fn.split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case \"") }
            .flatMap { line -> [String] in
                let labels = line.prefix(while: { $0 != ":" })
                return matches(#""([a-z_]+)""#, in: String(labels)).map { $0[1] }
            }
        XCTAssertGreaterThanOrEqual(types.count, 20,
                                    "found only \(types.count) frame types in SeqWire.topic(ofFrameType:): update this test's parser")
        return types
    }

    func testTheTopicTableMatchesTheDaemons() throws {
        let daemon = try daemonTopicTable()
        for (type, topic) in daemon.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(SeqWire.topic(ofFrameType: type), topic,
                           "the daemon puts \(type) in topic \(topic); the Kit disagrees")
        }
        for type in try kitFrameTypes() {
            XCTAssertNotNil(daemon[type], "the Kit puts \(type) in topic \(SeqWire.topic(ofFrameType: type) ?? "?"), the daemon names no topic for it")
        }
        XCTAssertNil(SeqWire.topic(ofFrameType: "session_state"), "a frame with no topic stays without one")
    }

    // MARK: merged turns in a replayed window

    /// A replayed frame is the live frame plus a number. A merged turn (`user_parts`) must come out
    /// of the replay byte-for-byte what it was live.
    func testAFrameWithAnAddedSeqDecodesTheSameMergedTurn() throws {
        var json = try JSONSerialization.jsonObject(
            with: Data(MergedTurnTests.mergedStarted.utf8)) as! [String: Any]
        json["seq"] = 7
        let replayed = try JSONSerialization.data(withJSONObject: json)
        guard case .sessionTurnDelta(_, .turnStarted(let turn)) = ServerMsg.decode(from: replayed) else {
            return XCTFail("a numbered frame must still decode")
        }
        XCTAssertEqual(turn.userParts, ["oh and backfill the rows", "use the new column name"])
        XCTAssertEqual(turn.userInput, "oh and backfill the rows\n\nuse the new column name")
    }

    // MARK: subscribe

    func testSubscribeWithoutResumeHasNoResumeKey() throws {
        let body = try JSONEncoder().encode(ClientSubscribe(topics: [], rendersDecisions: true))
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertNil(json["resume"], "an empty resume must not be on the wire: a daemon without seq sees today's frame")
    }

    func testSubscribeCarriesTheEpochOnlyAlongsideAResume() throws {
        func json(_ subscribe: ClientSubscribe) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(subscribe)) as! [String: Any]
        }
        let with = try json(ClientSubscribe(topics: [], rendersDecisions: true, resume: ["perri": 4], seqEpoch: 7))
        XCTAssertEqual(with["seq_epoch"] as? Int, 7)
        let without = try json(ClientSubscribe(topics: [], rendersDecisions: true, resume: [:], seqEpoch: 7))
        XCTAssertNil(without["seq_epoch"], "no resume: an epoch alone would only confuse a daemon")
        let unnamed = try json(ClientSubscribe(topics: [], rendersDecisions: true, resume: ["perri": 4], seqEpoch: nil))
        XCTAssertNil(unnamed["seq_epoch"])
        XCTAssertNotNil(unnamed["resume"])
    }

    func testSubscribeWithResumeCarriesTheMap() throws {
        let body = try JSONEncoder().encode(
            ClientSubscribe(topics: [], rendersDecisions: true, resume: ["perri": 4, "mother_jobs": 9]))
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(json["resume"] as? [String: Int], ["perri": 4, "mother_jobs": 9])
    }
}
