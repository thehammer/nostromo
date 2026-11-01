import XCTest
import NostromoKit

// `TaskRequests` (BA4): request/response for the two task verbs (`session_task_output`,
// `session_task_stop`). Every request gets an id the daemon echoes; one completion that runs exactly
// once; a 12 s timeout that sits above the daemon's own 10 s; a late or duplicate answer is ignored.
//
// No wall clock and no daemon: the sender records what it is asked, timeouts are a list the test runs
// by hand, and an answer is a decoded wire value handed to `ingest` (what `AppStore` does with a frame).

final class TaskRequestsTests: XCTestCase {

    // MARK: - Fakes

    private final class Sender: TaskRequestSending {
        struct Output: Equatable {
            let requestId: String
            let tag: String
            let taskId: String
            let offset: UInt64?
            let maxBytes: UInt32
        }
        struct Stop: Equatable {
            let requestId: String
            let tag: String
            let taskId: String
        }

        private(set) var outputs: [Output] = []
        private(set) var stops: [Stop] = []

        func sendTaskOutput(requestId: String, tag: String, taskId: String, offset: UInt64?, maxBytes: UInt32) {
            outputs.append(Output(requestId: requestId, tag: tag, taskId: taskId, offset: offset, maxBytes: maxBytes))
        }

        func sendTaskStop(requestId: String, tag: String, taskId: String) {
            stops.append(Stop(requestId: requestId, tag: tag, taskId: taskId))
        }
    }

    /// The timeouts `TaskRequests` asks for, run by hand.
    private final class ManualTimeouts {
        private(set) var scheduled: [(delay: TimeInterval, work: () -> Void)] = []

        func schedule(_ delay: TimeInterval, _ work: @escaping () -> Void) {
            scheduled.append((delay, work))
        }

        func fireAll() {
            let due = scheduled
            scheduled = []
            for item in due { item.work() }
        }
    }

    private struct World {
        let requests: TaskRequests
        let sender: Sender
        let timeouts: ManualTimeouts
    }

    /// Default request ids (the real ones: unique per request), a recording sender, hand-run timeouts.
    private func makeWorld(connected: Bool = true) -> World {
        let timeouts = ManualTimeouts()
        let sender = Sender()
        let requests = TaskRequests(schedule: timeouts.schedule)
        if connected { requests.sender = sender }
        return World(requests: requests, sender: sender, timeouts: timeouts)
    }

    // MARK: - Answers as the daemon sends them

    private func outputAnswer(_ id: String, text: String = "hello\n", tag: String = "kate",
                              taskId: String = "t1") throws -> ServerMsg {
        let json: [String: Any] = [
            "request_id": id, "tag": tag, "task_id": taskId, "outcome": "ok", "text": text,
            "start_offset": 0, "end_offset": text.utf8.count, "total_bytes": text.utf8.count, "source": "file",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        return .sessionTaskOutputResult(try JSONDecoder().decode(SessionTaskOutputResultWire.self, from: data))
    }

    private func stopAnswer(_ id: String, outcome: String = "accepted", tag: String = "kate",
                            taskId: String = "t1") throws -> ServerMsg {
        let json: [String: Any] = ["request_id": id, "tag": tag, "task_id": taskId, "outcome": outcome]
        let data = try JSONSerialization.data(withJSONObject: json)
        return .sessionTaskStopResult(try JSONDecoder().decode(SessionTaskStopResultWire.self, from: data))
    }

    // MARK: - Reading a reply

    private func answer<A>(_ reply: TaskReply<A>) -> A? {
        if case .answered(let value) = reply { return value }
        return nil
    }

    private func isTimedOut<A>(_ reply: TaskReply<A>) -> Bool {
        if case .timedOut = reply { return true }
        return false
    }

    private func failureReason<A>(_ reply: TaskReply<A>) -> String? {
        if case .failed(let reason) = reply { return reason }
        return nil
    }

    // MARK: - Ids

    func testEveryRequestGetsADistinctIdAndTheSenderReceivesExactlyThatId() throws {
        let world = makeWorld()
        var ids: [String] = []
        for index in 0..<10 {
            ids.append(try XCTUnwrap(world.requests.requestOutput(tag: "kate", taskId: "t\(index)", offset: nil) { _ in }))
        }
        for index in 0..<10 {
            ids.append(try XCTUnwrap(world.requests.requestStop(tag: "kate", taskId: "t\(index)") { _ in }))
        }

        XCTAssertEqual(Set(ids).count, 20, "no two requests share an id")
        XCTAssertFalse(ids.contains(""), "an id is never empty")
        XCTAssertEqual(world.sender.outputs.map(\.requestId), Array(ids[0..<10]), "the sender got the returned ids, in order")
        XCTAssertEqual(world.sender.stops.map(\.requestId), Array(ids[10..<20]))
        XCTAssertEqual(world.requests.pendingCount, 20)
    }

    func testTheRequestAsAskedReachesTheSenderUnchanged() throws {
        let world = makeWorld()
        world.requests.requestOutput(tag: "kate", taskId: "b1", offset: nil) { _ in }
        world.requests.requestOutput(tag: "cody", taskId: "b2", offset: 4_096, maxBytes: 512) { _ in }
        world.requests.requestStop(tag: "ada", taskId: "b3") { _ in }

        let outputs = world.sender.outputs
        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(outputs[0].tag, "kate")
        XCTAssertEqual(outputs[0].taskId, "b1")
        XCTAssertNil(outputs[0].offset, "no offset means the tail")
        XCTAssertEqual(outputs[0].maxBytes, 1_048_576, "a read asks for at most 1 MiB unless told less")
        XCTAssertEqual(outputs[1].tag, "cody")
        XCTAssertEqual(outputs[1].taskId, "b2")
        XCTAssertEqual(outputs[1].offset, 4_096)
        XCTAssertEqual(outputs[1].maxBytes, 512)
        XCTAssertEqual(world.sender.stops.map(\.tag), ["ada"])
        XCTAssertEqual(world.sender.stops.map(\.taskId), ["b3"])
    }

    // MARK: - Answers are matched by request id

    func testAnOutputAnswerResolvesOnlyTheRequestWhoseIdItCarries() throws {
        let world = makeWorld()
        var first: [TaskReply<SessionTaskOutputResultWire>] = []
        var second: [TaskReply<SessionTaskOutputResultWire>] = []
        let firstId = try XCTUnwrap(world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { first.append($0) })
        let secondId = try XCTUnwrap(world.requests.requestOutput(tag: "kate", taskId: "t1", offset: 100) { second.append($0) })

        world.requests.ingest(try outputAnswer(secondId, text: "for the second\n"))

        XCTAssertEqual(first.count, 0, "the first request is still waiting")
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first.flatMap { answer($0) }?.text, "for the second\n")
        XCTAssertEqual(second.first.flatMap { answer($0) }?.requestId, secondId)
        XCTAssertEqual(world.requests.pendingCount, 1)

        world.requests.ingest(try outputAnswer(firstId, text: "for the first\n"))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first.flatMap { answer($0) }?.text, "for the first\n")
        XCTAssertEqual(second.count, 1, "answering the first does not touch the second")
        XCTAssertEqual(world.requests.pendingCount, 0)
    }

    func testAStopAnswerResolvesOnlyTheRequestWhoseIdItCarries() throws {
        let world = makeWorld()
        var first: [TaskReply<SessionTaskStopResultWire>] = []
        var second: [TaskReply<SessionTaskStopResultWire>] = []
        let firstId = try XCTUnwrap(world.requests.requestStop(tag: "kate", taskId: "t1") { first.append($0) })
        let secondId = try XCTUnwrap(world.requests.requestStop(tag: "kate", taskId: "t2") { second.append($0) })

        world.requests.ingest(try stopAnswer(secondId, outcome: "refused"))

        XCTAssertEqual(first.count, 0)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second.first.flatMap { answer($0) }?.outcome, .refused)

        world.requests.ingest(try stopAnswer(firstId, outcome: "accepted"))
        XCTAssertEqual(first.first.flatMap { answer($0) }?.outcome, .accepted)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(world.requests.pendingCount, 0)
    }

    func testAnAnswerForAnIdNobodyWaitsForIsIgnored() throws {
        let world = makeWorld()
        var replies: [TaskReply<SessionTaskOutputResultWire>] = []
        world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { replies.append($0) }

        world.requests.ingest(try outputAnswer("nobody-asked-for-this"))
        world.requests.ingest(try stopAnswer("nobody-asked-for-this-either"))

        XCTAssertEqual(replies.count, 0)
        XCTAssertEqual(world.requests.pendingCount, 1, "the real request is still waiting")
    }

    // MARK: - Exactly once

    func testEachCompletionRunsExactlyOnceWhateverArrivesAfterItsAnswer() throws {
        let world = makeWorld()
        var outputs = 0
        var stops = 0
        let outputId = try XCTUnwrap(world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { _ in outputs += 1 })
        let stopId = try XCTUnwrap(world.requests.requestStop(tag: "kate", taskId: "t1") { _ in stops += 1 })

        world.requests.ingest(try outputAnswer(outputId))
        world.requests.ingest(try stopAnswer(stopId))
        XCTAssertEqual([outputs, stops], [1, 1])

        world.requests.ingest(try outputAnswer(outputId))     // a duplicate
        world.requests.ingest(try stopAnswer(stopId))
        world.timeouts.fireAll()                              // the timeouts of requests already answered
        world.requests.failPendingRequests(reason: "gone")    // a disconnect afterwards
        XCTAssertEqual([outputs, stops], [1, 1], "nothing that arrives after the answer runs a completion again")
        XCTAssertEqual(world.requests.pendingCount, 0)
    }

    func testADuplicateAnswerIsIgnored() throws {
        let world = makeWorld()
        var replies: [TaskReply<SessionTaskOutputResultWire>] = []
        let id = try XCTUnwrap(world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { replies.append($0) })

        world.requests.ingest(try outputAnswer(id, text: "first\n"))
        world.requests.ingest(try outputAnswer(id, text: "second\n"))

        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies.first.flatMap { answer($0) }?.text, "first\n", "the first answer wins")
    }

    // MARK: - Timeout

    func testSilenceEndsAsTimedOutAfterTwelveSecondsForBothVerbs() throws {
        let world = makeWorld()
        var outputs: [TaskReply<SessionTaskOutputResultWire>] = []
        var stops: [TaskReply<SessionTaskStopResultWire>] = []
        world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { outputs.append($0) }
        world.requests.requestStop(tag: "kate", taskId: "t1") { stops.append($0) }

        XCTAssertEqual(world.timeouts.scheduled.map { $0.delay }, [12, 12],
                       "both verbs wait 12 s, above the daemon's own 10 s, so its answer wins when it has one")
        XCTAssertEqual(outputs.count + stops.count, 0, "nothing resolves before the time is up")

        world.timeouts.fireAll()

        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(stops.count, 1)
        XCTAssertTrue(outputs.first.map { isTimedOut($0) } ?? false)
        XCTAssertTrue(stops.first.map { isTimedOut($0) } ?? false)
        XCTAssertEqual(world.requests.pendingCount, 0)
    }

    func testAnAnswerThatArrivesAfterTheTimeoutIsIgnored() throws {
        let world = makeWorld()
        var outputs: [TaskReply<SessionTaskOutputResultWire>] = []
        var stops: [TaskReply<SessionTaskStopResultWire>] = []
        let outputId = try XCTUnwrap(world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { outputs.append($0) })
        let stopId = try XCTUnwrap(world.requests.requestStop(tag: "kate", taskId: "t1") { stops.append($0) })
        world.timeouts.fireAll()

        world.requests.ingest(try outputAnswer(outputId))
        world.requests.ingest(try stopAnswer(stopId))

        XCTAssertEqual(outputs.count, 1, "the timeout was the one completion")
        XCTAssertEqual(stops.count, 1)
        XCTAssertTrue(outputs.first.map { isTimedOut($0) } ?? false)
        XCTAssertTrue(stops.first.map { isTimedOut($0) } ?? false)
    }

    // MARK: - Connection lost

    func testLosingTheConnectionFailsEveryWaiterWithTheReason() throws {
        let world = makeWorld()
        var outputs: [TaskReply<SessionTaskOutputResultWire>] = []
        var stops: [TaskReply<SessionTaskStopResultWire>] = []
        world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { outputs.append($0) }
        world.requests.requestOutput(tag: "kate", taskId: "t2", offset: 10) { outputs.append($0) }
        world.requests.requestStop(tag: "kate", taskId: "t1") { stops.append($0) }
        XCTAssertEqual(world.requests.pendingCount, 3)

        world.requests.failPendingRequests(reason: "The connection to the daemon was lost")

        XCTAssertEqual(outputs.count, 2)
        XCTAssertEqual(stops.count, 1)
        for reply in outputs { XCTAssertEqual(failureReason(reply), "The connection to the daemon was lost") }
        for reply in stops { XCTAssertEqual(failureReason(reply), "The connection to the daemon was lost") }
        XCTAssertEqual(world.requests.pendingCount, 0)
    }

    func testAnAnswerThatArrivesAfterTheConnectionFailureIsIgnored() throws {
        let world = makeWorld()
        var outputs: [TaskReply<SessionTaskOutputResultWire>] = []
        var stops: [TaskReply<SessionTaskStopResultWire>] = []
        let outputId = try XCTUnwrap(world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { outputs.append($0) })
        let stopId = try XCTUnwrap(world.requests.requestStop(tag: "kate", taskId: "t1") { stops.append($0) })
        world.requests.failPendingRequests(reason: "gone")

        world.requests.ingest(try outputAnswer(outputId))
        world.requests.ingest(try stopAnswer(stopId))
        world.timeouts.fireAll()

        XCTAssertEqual(outputs.count, 1, "the failure was the one completion")
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(outputs.first.flatMap { failureReason($0) }, "gone")
    }

    func testFailingWithNothingPendingDoesNothing() {
        let world = makeWorld()
        world.requests.failPendingRequests(reason: "gone")
        XCTAssertEqual(world.requests.pendingCount, 0)
    }

    // MARK: - No connection

    func testWithNoConnectionARequestFailsAtOnceAndNothingStaysPending() {
        let world = makeWorld(connected: false)
        var outputs: [TaskReply<SessionTaskOutputResultWire>] = []
        var stops: [TaskReply<SessionTaskStopResultWire>] = []

        let outputId = world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { outputs.append($0) }
        let stopId = world.requests.requestStop(tag: "kate", taskId: "t1") { stops.append($0) }

        XCTAssertNil(outputId, "no request was made, so there is no id")
        XCTAssertNil(stopId)
        XCTAssertEqual(outputs.count, 1, "the completion ran at once, before the call returned")
        XCTAssertEqual(stops.count, 1)
        XCTAssertFalse(outputs.first.flatMap { failureReason($0) }?.isEmpty ?? true, "and says why")
        XCTAssertFalse(stops.first.flatMap { failureReason($0) }?.isEmpty ?? true)
        XCTAssertEqual(world.requests.pendingCount, 0)
        XCTAssertTrue(world.timeouts.scheduled.isEmpty, "no timeout is left waiting for nothing")
    }

    func testARequestMadeAfterTheConnectionReturnsIsSentNormally() throws {
        let world = makeWorld(connected: false)
        world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { _ in }
        XCTAssertTrue(world.sender.outputs.isEmpty)

        world.requests.sender = world.sender
        let id = try XCTUnwrap(world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { _ in })

        XCTAssertEqual(world.sender.outputs.map(\.requestId), [id])
        XCTAssertEqual(world.requests.pendingCount, 1)
    }

    // MARK: - Frames that are not answers

    func testAFrameThatIsNotATaskAnswerIsIgnored() {
        let world = makeWorld()
        var replies = 0
        world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { _ in replies += 1 }
        world.requests.requestStop(tag: "kate", taskId: "t1") { _ in replies += 1 }

        world.requests.ingest(.sessionTasks(SessionTasksWire(tag: "kate", daemonEpoch: "e1", tasks: [])))
        world.requests.ingest(.sessionTaskDetail(SessionTaskDetailWire(tag: "kate", taskId: "t1", preview: "x")))

        XCTAssertEqual(replies, 0)
        XCTAssertEqual(world.requests.pendingCount, 2)
    }

    // MARK: - Chained requests

    func testARequestMadeFromInsideACompletionIsIndependent() throws {
        let world = makeWorld()
        var chainedId: String?
        var chainedReplies = 0
        let firstId = try XCTUnwrap(world.requests.requestOutput(tag: "kate", taskId: "t1", offset: nil) { [world] _ in
            chainedId = world.requests.requestOutput(tag: "kate", taskId: "t1", offset: 64) { _ in chainedReplies += 1 }
        })

        world.requests.ingest(try outputAnswer(firstId))

        let second = try XCTUnwrap(chainedId)
        XCTAssertNotEqual(second, firstId)
        XCTAssertEqual(world.requests.pendingCount, 1, "only the chained request waits")
        XCTAssertEqual(world.sender.outputs.last?.offset, 64)
        world.requests.ingest(try outputAnswer(second))
        XCTAssertEqual(chainedReplies, 1)
        XCTAssertEqual(world.requests.pendingCount, 0)
    }
}
