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
                               ("something_new", .unknown)] {
            let msg = ServerMsg.decode(from: data(
                #"{"type":"gap","topic":"perri","host":"kobe","from":1,"to":2,"reason":"\#(wire)"}"#))
            guard case .gap(_, let host, _, _, let got) = msg else { return XCTFail("not a gap") }
            XCTAssertEqual(got, reason, wire)
            XCTAssertEqual(host, "kobe")
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

    func testSubscribeWithResumeCarriesTheMap() throws {
        let body = try JSONEncoder().encode(
            ClientSubscribe(topics: [], rendersDecisions: true, resume: ["perri": 4, "mother_jobs": 9]))
        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(json["resume"] as? [String: Int], ["perri": 4, "mother_jobs": 9])
    }
}
