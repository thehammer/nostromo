// NostromoKit — MotherJobAnnotationTests.swift
//
// Mother focus v2, MF1: `MotherJob.nostromo`, the daemon's own note on who
// queued a job, as the shared Kit decodes it.
//
// `tests/fixtures/mother-v2/mother-jobs-annotated.json` is the daemon's own
// `ServerMsg::MotherJobs` frame (written by `tests/mother_origin.rs` with
// `UPDATE_GOLDEN=1`). It holds seven jobs:
//
//   j-focus        origin kind focus, with names, closed false, a session prefix, notify, notice
//   j-unverified   origin kind unverified (a claimed tag, no session prefix)
//   j-you          origin kind you, notify off
//   j-unknown      origin kind unknown
//   j-robot        an origin kind this Kit has never heard of (a future daemon)
//   j-bad-string   `"nostromo": "oops"`
//   j-bad-origin   `"nostromo": {"origin": 7, "notify": "wake"}`
//
// The contract: an annotation costs only itself. A kind the Kit does not know
// decodes as `.other(raw)` and never throws; a malformed annotation leaves
// `nostromo == nil` and the job, with every other field, intact; one bad
// annotation never drops a job from a `mother_jobs` frame.

import XCTest
@testable import NostromoKit

final class MotherJobAnnotationTests: XCTestCase {

    // MARK: - Fixture access

    /// `<repo>/tests/fixtures/mother-v2/mother-jobs-annotated.json`, found from this
    /// file's location (`<repo>/Shared/NostromoKit/Tests/NostromoKitTests/`), the same
    /// `#filePath` pattern `MotherCrewWireTests` uses.
    private static let goldenURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NostromoKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NostromoKit
        .deletingLastPathComponent()   // Shared
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("tests/fixtures/mother-v2/mother-jobs-annotated.json")

    private static let plainGoldenURL: URL = goldenURL
        .deletingLastPathComponent()   // mother-v2
        .deletingLastPathComponent()   // fixtures
        .appendingPathComponent("mother-contract/ipc_mother_jobs_plain.golden.json")

    private static let jobIds = [
        "j-focus", "j-unverified", "j-you", "j-unknown", "j-robot", "j-bad-string", "j-bad-origin",
    ]

    private func goldenData() throws -> Data {
        try Data(contentsOf: Self.goldenURL)
    }

    /// The `jobs` array of the golden frame as raw JSON objects.
    private func goldenJobObjects() throws -> [[String: Any]] {
        let root = try JSONSerialization.jsonObject(with: try goldenData())
        let frame = try XCTUnwrap(root as? [String: Any], "the golden is not a JSON object")
        XCTAssertEqual(frame["type"] as? String, "mother_jobs")
        return try XCTUnwrap(frame["jobs"] as? [[String: Any]], "the golden has no jobs array")
    }

    private func decodeJob(_ object: [String: Any]) throws -> MotherJob {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(MotherJob.self, from: data)
    }

    /// Every golden job decoded one by one the way a job decodes on its own.
    private func goldenJobs() throws -> [String: MotherJob] {
        var out: [String: MotherJob] = [:]
        for object in try goldenJobObjects() {
            let job = try decodeJob(object)
            out[job.id] = job
        }
        return out
    }

    private func job(_ id: String, file: StaticString = #filePath, line: UInt = #line) throws -> MotherJob {
        try XCTUnwrap(try goldenJobs()[id], "\(id) is not in the golden", file: file, line: line)
    }

    // MARK: - Every kind decodes with its fields

    func testGoldenHoldsEverySeededJob() throws {
        XCTAssertEqual(try goldenJobObjects().compactMap { $0["id"] as? String }, Self.jobIds)
    }

    func testAFocusOriginDecodesWithItsNamesClosedFlagSessionPrefixAndNotify() throws {
        let annotation = try XCTUnwrap(try job("j-focus").nostromo)
        let origin = try XCTUnwrap(annotation.origin)
        XCTAssertEqual(origin.kind, .focus)
        XCTAssertEqual(origin.focusTag, "claudia-C9D6B773")
        XCTAssertEqual(origin.nameSnapshot, "Fix login")
        XCTAssertEqual(origin.focusName, "Fix the login flow")
        XCTAssertEqual(origin.closed, false)
        XCTAssertEqual(origin.sessionPrefix, "5f3c9a10")
        XCTAssertEqual(annotation.notify, "quiet")
    }

    func testAnUnverifiedOriginDecodesWithTheClaimedTagAndNoSessionOrClosedFlag() throws {
        let annotation = try XCTUnwrap(try job("j-unverified").nostromo)
        let origin = try XCTUnwrap(annotation.origin)
        XCTAssertEqual(origin.kind, .unverified)
        XCTAssertEqual(origin.focusTag, "claudia-D00DFEED")
        XCTAssertEqual(origin.nameSnapshot, "Claimed name")
        XCTAssertNil(origin.focusName)
        XCTAssertNil(origin.closed)
        XCTAssertNil(origin.sessionPrefix)
        XCTAssertNil(annotation.notify)
    }

    func testAYouOriginDecodesWithNoFocusAtAllAndItsNotify() throws {
        let annotation = try XCTUnwrap(try job("j-you").nostromo)
        let origin = try XCTUnwrap(annotation.origin)
        XCTAssertEqual(origin.kind, .you)
        XCTAssertNil(origin.focusTag)
        XCTAssertNil(origin.nameSnapshot)
        XCTAssertNil(origin.focusName)
        XCTAssertNil(origin.closed)
        XCTAssertNil(origin.sessionPrefix)
        XCTAssertEqual(annotation.notify, "off")
    }

    func testAnUnknownOriginDecodesAsUnknown() throws {
        let origin = try XCTUnwrap(try job("j-unknown").nostromo?.origin)
        XCTAssertEqual(origin.kind, .unknown)
        XCTAssertNil(origin.focusTag)
        XCTAssertNil(try job("j-unknown").nostromo?.notify)
    }

    // MARK: - A kind the Kit does not know

    func testAnOriginKindFromAFutureDaemonDecodesAsOtherWithTheRawStringAndKeepsTheRestOfTheAnnotation() throws {
        let robot = try job("j-robot")
        let annotation = try XCTUnwrap(robot.nostromo, "an unknown kind must not cost the annotation")
        let origin = try XCTUnwrap(annotation.origin)
        XCTAssertEqual(origin.kind, .other("robot"))
        XCTAssertNotEqual(origin.kind, .unknown, "an unrecognised kind is not the daemon's `unknown`")
        XCTAssertEqual(origin.focusTag, "claudia-CAFE0001")
        XCTAssertEqual(origin.nameSnapshot, "Future focus")
        XCTAssertEqual(origin.focusName, "Future focus")
        XCTAssertEqual(annotation.notify, "wake")
        XCTAssertEqual(robot.title, "From a future daemon", "the job itself is intact")
    }

    func testAnUnknownKindNeverThrowsWhateverItsSpelling() throws {
        for raw in ["robot", "", "FOCUS", "focus ", "🤖", "a-very-long-kind-that-nobody-has-ever-heard-of"] {
            var object = try goldenJobObjects()[0]
            object["nostromo"] = ["origin": ["kind": raw, "focus_tag": "claudia-1"]]
            let decoded = try decodeJob(object)
            XCTAssertEqual(decoded.nostromo?.origin?.kind, .other(raw), "kind \(raw.debugDescription)")
            XCTAssertEqual(decoded.nostromo?.origin?.focusTag, "claudia-1")
        }
    }

    // MARK: - A malformed annotation costs only itself

    func testAMalformedAnnotationLeavesNoAnnotationAndTheJobWithItsOtherFieldsIntact() throws {
        for (id, title) in [
            ("j-bad-string", "Annotation is a string"),
            ("j-bad-origin", "Origin is a number"),
        ] {
            let j = try job(id)
            XCTAssertNil(j.nostromo, "\(id): a malformed annotation reads as none")
            XCTAssertEqual(j.id, id)
            XCTAssertEqual(j.title, title)
            XCTAssertEqual(j.repo, "nostromo")
            XCTAssertEqual(j.createdAt, "2026-10-20T15:00:00Z")
            XCTAssertEqual(j.originLabel, "nightly", "\(id): the label is still read")
        }
    }

    func testAnAnnotationOfTheWrongShapeNeverThrows() throws {
        let base = try goldenJobObjects()[3]
        let wrongShapes: [Any] = [
            "oops", 7, true, [1, 2, 3],
            ["origin": "focus"],
            ["origin": ["kind": 5]],
            ["origin": [String: Any](), "notify": 9],
            NSNull(),
        ]
        for bad in wrongShapes {
            var object = base
            object["nostromo"] = bad
            let decoded = try decodeJob(object)
            XCTAssertEqual(decoded.id, "j-unknown", "bad annotation \(bad)")
            XCTAssertEqual(decoded.title, "Queued from a shell", "bad annotation \(bad)")
        }
    }

    // MARK: - A bad key costs only that key

    private func decodeAnnotation(_ json: String) throws -> MotherJobAnnotation {
        try JSONDecoder().decode(MotherJobAnnotation.self, from: Data(json.utf8))
    }

    func testAWrongTypedNotifyKeepsAValidOrigin() throws {
        for notify in ["7", "true", "[\"quiet\"]", "{\"level\": \"quiet\"}", "1.5"] {
            let annotation = try decodeAnnotation(
                #"{"origin":{"kind":"focus","focus_tag":"t","name_snapshot":"Fix login"},"notify":\#(notify)}"#
            )
            let origin = try XCTUnwrap(annotation.origin, "notify \(notify) must not cost the origin")
            XCTAssertEqual(origin.kind, .focus, "notify \(notify)")
            XCTAssertEqual(origin.focusTag, "t", "notify \(notify)")
            XCTAssertEqual(origin.nameSnapshot, "Fix login", "notify \(notify)")
            XCTAssertNil(annotation.notify, "a notify of the wrong type reads as none: \(notify)")
        }
    }

    func testAWrongShapedOriginKeepsAValidNotify() throws {
        for origin in ["\"oops\"", "{\"kind\": 5}", "7", "[1, 2]", "{\"closed\": \"yes\"}"] {
            let annotation = try decodeAnnotation(#"{"origin":\#(origin),"notify":"quiet"}"#)
            XCTAssertNil(annotation.origin, "origin \(origin) is malformed and reads as none")
            XCTAssertEqual(annotation.notify, "quiet", "origin \(origin) must not cost the notify")
        }
    }

    func testABadKeyAlongsideAGoodOneStillLeavesAnAnnotationOnTheJob() throws {
        var notifyBad = try goldenJobObjects()[3]
        notifyBad["nostromo"] = ["origin": ["kind": "focus", "focus_tag": "t"], "notify": 7] as [String: Any]
        let first = try decodeJob(notifyBad)
        XCTAssertEqual(first.nostromo?.origin?.kind, .focus)
        XCTAssertEqual(first.nostromo?.origin?.focusTag, "t")
        XCTAssertNil(first.nostromo?.notify)

        var notifyAsArray = try goldenJobObjects()[3]
        notifyAsArray["nostromo"] = ["origin": ["kind": "you"], "notify": ["quiet"]] as [String: Any]
        let second = try decodeJob(notifyAsArray)
        XCTAssertEqual(second.nostromo?.origin?.kind, .you)
        XCTAssertNil(second.nostromo?.notify)

        var originBad = try goldenJobObjects()[3]
        originBad["nostromo"] = ["origin": "oops", "notify": "quiet"] as [String: Any]
        let third = try decodeJob(originBad)
        XCTAssertNotNil(third.nostromo, "a valid notify keeps the annotation")
        XCTAssertNil(third.nostromo?.origin)
        XCTAssertEqual(third.nostromo?.notify, "quiet")

        var originBadKind = try goldenJobObjects()[3]
        originBadKind["nostromo"] = ["origin": ["kind": 5], "notify": "quiet"] as [String: Any]
        let fourth = try decodeJob(originBadKind)
        XCTAssertNil(fourth.nostromo?.origin)
        XCTAssertEqual(fourth.nostromo?.notify, "quiet")
    }

    func testAFrameWithPartlyBadAnnotationsKeepsEveryJobAndEachGoodKey() throws {
        var notifyBad = try goldenJobObjects()[3]
        notifyBad["id"] = "p-notify-bad"
        notifyBad["nostromo"] = ["origin": ["kind": "focus", "focus_tag": "t"], "notify": 7] as [String: Any]
        var originBad = try goldenJobObjects()[3]
        originBad["id"] = "p-origin-bad"
        originBad["nostromo"] = ["origin": ["kind": 5], "notify": "quiet"] as [String: Any]
        var fine = try goldenJobObjects()[3]
        fine["id"] = "p-fine"
        fine["nostromo"] = ["origin": ["kind": "you"], "notify": "off"] as [String: Any]
        let data = try JSONSerialization.data(
            withJSONObject: ["type": "mother_jobs", "jobs": [notifyBad, originBad, fine]] as [String: Any]
        )

        guard case .motherJobs(let jobs) = ServerMsg.decode(from: data) else {
            return XCTFail("a frame with partly bad annotations is still a mother_jobs message")
        }

        XCTAssertEqual(jobs.map(\.id), ["p-notify-bad", "p-origin-bad", "p-fine"], "no job is dropped or reordered")
        XCTAssertEqual(jobs[0].nostromo?.origin?.kind, .focus)
        XCTAssertEqual(jobs[0].nostromo?.origin?.focusTag, "t")
        XCTAssertNil(jobs[0].nostromo?.notify)
        XCTAssertNil(jobs[1].nostromo?.origin)
        XCTAssertEqual(jobs[1].nostromo?.notify, "quiet")
        XCTAssertEqual(jobs[2].nostromo?.origin?.kind, .you)
        XCTAssertEqual(jobs[2].nostromo?.notify, "off")
    }

    // MARK: - The whole frame, the way the apps decode it

    func testAWholeMotherJobsFrameDecodesEveryJobEvenWithMalformedAnnotations() throws {
        let message = ServerMsg.decode(from: try goldenData())
        guard case .motherJobs(let jobs) = message else {
            return XCTFail("the golden frame is a mother_jobs message, got \(message)")
        }
        XCTAssertEqual(jobs.map(\.id), Self.jobIds, "one bad annotation must not drop a job, nor reorder the list")
        let kinds: [MotherOriginKind?] = [.focus, .unverified, .you, .unknown, .other("robot"), nil, nil]
        XCTAssertEqual(jobs.map { $0.nostromo?.origin?.kind }, kinds)
        XCTAssertEqual(jobs[0].nostromo?.origin?.focusTag, "claudia-C9D6B773")
        XCTAssertEqual(jobs[5].title, "Annotation is a string")
        XCTAssertEqual(jobs[6].title, "Origin is a number")
    }

    func testAFrameWhereEveryAnnotationIsBrokenStillYieldsEveryJob() throws {
        var objects = try goldenJobObjects()
        for i in objects.indices { objects[i]["nostromo"] = "broken" }
        let data = try JSONSerialization.data(withJSONObject: ["type": "mother_jobs", "jobs": objects] as [String: Any])
        guard case .motherJobs(let jobs) = ServerMsg.decode(from: data) else {
            return XCTFail("a frame of unannotated-looking jobs is still a mother_jobs message")
        }
        XCTAssertEqual(jobs.map(\.id), Self.jobIds)
        XCTAssertTrue(jobs.allSatisfy { $0.nostromo == nil })
    }

    // MARK: - Round trip

    func testAJobWithAnAnnotationEncodesAndDecodesToTheSameJob() throws {
        for id in ["j-focus", "j-unverified", "j-you", "j-unknown", "j-robot"] {
            let original = try job(id)
            XCTAssertNotNil(original.nostromo, id)

            let encoded = try JSONEncoder().encode(original)
            let again = try JSONDecoder().decode(MotherJob.self, from: encoded)

            XCTAssertEqual(again, original, "\(id) survives encode then decode")
            XCTAssertEqual(again.nostromo, original.nostromo, id)
        }
    }

    func testTheAnnotationIsEncodedInTheDaemonsSnakeCaseKeys() throws {
        let encoded = try JSONEncoder().encode(try job("j-focus"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let nostromo = try XCTUnwrap(object["nostromo"] as? [String: Any], "an annotation is encoded when present")
        XCTAssertEqual(nostromo["notify"] as? String, "quiet")
        let origin = try XCTUnwrap(nostromo["origin"] as? [String: Any])
        XCTAssertEqual(origin["kind"] as? String, "focus")
        XCTAssertEqual(origin["focus_tag"] as? String, "claudia-C9D6B773")
        XCTAssertEqual(origin["name_snapshot"] as? String, "Fix login")
        XCTAssertEqual(origin["focus_name"] as? String, "Fix the login flow")
        XCTAssertEqual(origin["closed"] as? Bool, false)
        XCTAssertEqual(origin["session_prefix"] as? String, "5f3c9a10")
    }

    func testAnUnrecognisedKindIsWrittenBackAsItsRawString() throws {
        let encoded = try JSONEncoder().encode(try job("j-robot"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let origin = try XCTUnwrap((object["nostromo"] as? [String: Any])?["origin"] as? [String: Any])
        XCTAssertEqual(origin["kind"] as? String, "robot")
    }

    // MARK: - Jobs without an annotation

    func testAJobWithoutAnAnnotationHasNoneAndEncodesWithoutTheKey() throws {
        var object = try goldenJobObjects()[3]
        object.removeValue(forKey: "nostromo")
        let decoded = try decodeJob(object)
        XCTAssertNil(decoded.nostromo)

        let encoded = try JSONEncoder().encode(decoded)
        let written = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(written["nostromo"], "no annotation, no key")
        XCTAssertEqual(try JSONDecoder().decode(MotherJob.self, from: encoded), decoded)
    }

    func testAMalformedAnnotationIsNotWrittenBack() throws {
        let encoded = try JSONEncoder().encode(try job("j-bad-string"))
        let written = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(written["nostromo"])
    }

    func testAnExplicitNullAnnotationIsNone() throws {
        var object = try goldenJobObjects()[0]
        object["nostromo"] = NSNull()
        let decoded = try decodeJob(object)
        XCTAssertNil(decoded.nostromo)
        XCTAssertEqual(decoded.id, "j-focus")
    }

    func testTheDaemonsPlainGoldenStillDecodesWithNoAnnotationOnAnyJob() throws {
        let data = try Data(contentsOf: Self.plainGoldenURL)
        guard case .motherJobs(let jobs) = ServerMsg.decode(from: data) else {
            return XCTFail("the plain golden is a mother_jobs message")
        }
        XCTAssertGreaterThanOrEqual(jobs.count, 5)
        XCTAssertTrue(jobs.allSatisfy { $0.nostromo == nil }, "jobs the daemon did not annotate carry none")
    }
}
