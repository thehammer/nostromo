// PushDetailFetcherTests.swift
//
// The fetch's hard budget (W16): the extension gets about 30 s from iOS and must always hand over a
// notification, so the whole round trip gets 4.0 s and not a moment more. Anything that goes wrong
// (stall, refusal, garbage, a reply for another item) is `nil`, never an error and never a wait.
//
// Time is a `ManualClock`: a test says "the fetch is waiting", then moves fake time. No test here
// sleeps on the wall clock, so a fetch that returns at 4.0 fake seconds returns at 4.0 fake seconds
// on a slow machine too.

import XCTest
@testable import NostromoKit

final class PushDetailFetcherTests: XCTestCase {

    private func makeClock() -> ManualClock {
        let clock = ManualClock()
        addTeardownBlock { clock.drain() }
        return clock
    }

    private struct Run {
        let task: Task<PushDetailWire?, Never>
        /// The clock's reading at the moment the fetch returned; set only once it has.
        let returnedAt: Box<TimeInterval>
    }

    /// Starts a fetch on its own task so the test can move fake time while it waits.
    private func start(_ transport: FakeDetailTransport, clock: ManualClock,
                       itemRef: String = "item-1", deadline: TimeInterval? = nil) -> Run {
        let fetcher = PushDetailFetcher(transport: transport, clock: clock)
        let returnedAt = Box<TimeInterval>()
        let task = Task { () -> PushDetailWire? in
            let detail: PushDetailWire?
            if let deadline {
                detail = await fetcher.fetch(itemRef: itemRef, deadline: deadline)
            } else {
                detail = await fetcher.fetch(itemRef: itemRef)
            }
            returnedAt.set(clock.now)
            return detail
        }
        return Run(task: task, returnedAt: returnedAt)
    }

    private func settled(_ clock: ManualClock) async {
        await clock.settle()
    }

    // MARK: - Within the budget

    func testTheBudgetIsFourSeconds() {
        XCTAssertEqual(PushDetailFetcher.budget, 4.0)
    }

    func testAReplyAtThreePointNineSecondsIsReturned() async {
        let clock = makeClock()
        let transport = FakeDetailTransport(.reply(detailFrame(itemRef: "item-1", text: "Rename the helper?"), after: 3.9),
                                            clock: clock)
        let run = start(transport, clock: clock)
        let waiting = await clock.waitForSleepers(2)
        XCTAssertTrue(waiting, "the transport and the deadline are both waiting")

        await clock.advance(by: 3.9)
        let detail = await run.task.value

        XCTAssertEqual(detail?.itemRef, "item-1")
        XCTAssertEqual(detail?.text, "Rename the helper?")
        XCTAssertEqual(detail?.waiting, true)
        XCTAssertFalse(transport.wasCancelled)
        XCTAssertEqual(transport.requestedRefs, ["item-1"])
    }

    func testAnImmediateReplyIsReturnedWithoutAnyTimePassing() async {
        let clock = makeClock()
        let transport = FakeDetailTransport(.reply(detailFrame(itemRef: "item-1"), after: 0), clock: clock)
        let detail = await PushDetailFetcher(transport: transport, clock: clock).fetch(itemRef: "item-1")
        XCTAssertEqual(detail?.itemRef, "item-1")
        XCTAssertEqual(clock.now, 0)
    }

    // MARK: - Past the budget

    func testAStallPastTheBudgetIsNilByFourPointZeroFiveSecondsAndTheTransportIsCancelled() async {
        let clock = makeClock()
        let transport = FakeDetailTransport(.reply(detailFrame(itemRef: "item-1"), after: 4.1), clock: clock)
        let run = start(transport, clock: clock)
        let waiting = await clock.waitForSleepers(2)
        XCTAssertTrue(waiting)

        await clock.advance(by: 3.99)
        await settled(clock)
        XCTAssertFalse(run.returnedAt.isSet, "it keeps waiting until the budget is spent")

        await clock.advance(by: 0.06)   // fake time is now 4.05
        let returned = await yieldUntil { run.returnedAt.isSet }
        XCTAssertTrue(returned, "the fetch has returned by 4.05 fake seconds")
        let detail = await run.task.value

        XCTAssertNil(detail)
        let reading = run.returnedAt.value ?? -1
        XCTAssertGreaterThanOrEqual(reading, 4.0, "not before the budget")
        XCTAssertLessThanOrEqual(reading, 4.05 + 0.001, "and no later than 4.05")
        let cancelled = await yieldUntil { transport.wasCancelled }
        XCTAssertTrue(cancelled, "the abandoned request is told to stop (it closes its socket)")
    }

    func testARefusedConnectionIsNilAtOnceWithNoTimePassing() async {
        let clock = makeClock()
        let transport = FakeDetailTransport(.refuse, clock: clock)
        let detail = await PushDetailFetcher(transport: transport, clock: clock).fetch(itemRef: "item-1")
        XCTAssertNil(detail)
        XCTAssertEqual(clock.now, 0, "it did not wait for anything")
        XCTAssertEqual(transport.requestedRefs, ["item-1"])
    }

    // MARK: - The deadline argument

    func testALongerDeadlineIsClampedToTheBudget() async {
        let clock = makeClock()
        let transport = FakeDetailTransport(.reply(detailFrame(itemRef: "item-1"), after: 100), clock: clock)
        let run = start(transport, clock: clock, deadline: 30)
        let waiting = await clock.waitForSleepers(2)
        XCTAssertTrue(waiting)

        await clock.advance(by: 3.99)
        await settled(clock)
        XCTAssertFalse(run.returnedAt.isSet)
        await clock.advance(by: 0.06)

        let returned = await yieldUntil { run.returnedAt.isSet }
        XCTAssertTrue(returned, "a 30 s deadline still ends at the 4 s budget")
        let detail = await run.task.value
        XCTAssertNil(detail)
    }

    func testAShorterDeadlineIsHonoured() async {
        let clock = makeClock()
        let transport = FakeDetailTransport(.reply(detailFrame(itemRef: "item-1"), after: 100), clock: clock)
        let run = start(transport, clock: clock, deadline: 1.0)
        let waiting = await clock.waitForSleepers(2)
        XCTAssertTrue(waiting)

        await clock.advance(by: 0.9)
        await settled(clock)
        XCTAssertFalse(run.returnedAt.isSet, "not before the shorter deadline")
        await clock.advance(by: 0.15)

        let returned = await yieldUntil { run.returnedAt.isSet }
        XCTAssertTrue(returned, "ended at 1 s, long before the 4 s budget")
        let detail = await run.task.value
        XCTAssertNil(detail)
        XCTAssertLessThanOrEqual(clock.now, 1.05 + 0.001)
    }

    func testAShorterDeadlineStillTakesAnAnswerThatArrivesInTime() async {
        let clock = makeClock()
        let transport = FakeDetailTransport(.reply(detailFrame(itemRef: "item-1"), after: 0.5), clock: clock)
        let run = start(transport, clock: clock, deadline: 1.0)
        let waiting = await clock.waitForSleepers(2)
        XCTAssertTrue(waiting)
        await clock.advance(by: 0.5)
        let detail = await run.task.value
        XCTAssertEqual(detail?.itemRef, "item-1")
    }

    // MARK: - What the answer says

    func testWaitingFalseIsSurfacedAsAnAnswerNotHidden() async {
        let clock = makeClock()
        let transport = FakeDetailTransport(.reply(detailFrame(itemRef: "item-1", waiting: false, text: nil), after: 0),
                                            clock: clock)
        let detail = await PushDetailFetcher(transport: transport, clock: clock).fetch(itemRef: "item-1")
        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.waiting, false)
        XCTAssertNil(detail?.text)
    }

    func testAWithheldTextIsSurfacedAsAnAnswerWithNoText() async {
        let clock = makeClock()
        let transport = FakeDetailTransport(.reply(detailFrame(itemRef: "item-1", waiting: true, text: nil), after: 0),
                                            clock: clock)
        let detail = await PushDetailFetcher(transport: transport, clock: clock).fetch(itemRef: "item-1")
        XCTAssertEqual(detail?.waiting, true)
        XCTAssertNil(detail?.text)
    }

    func testAnAnswerThatIsNotAPushDetailForThisItemIsNil() async {
        var oversized = detailFrame(itemRef: "item-1")
        oversized.append(Data(repeating: 0x20, count: PushDetailWire.maxFrameBytes))
        let answers: [(String, Data)] = [
            ("another item", detailFrame(itemRef: "item-2")),
            ("the wrong type", Data(#"{"type":"welcome","item_ref":"item-1","waiting":true}"#.utf8)),
            ("garbage", Data("not json at all".utf8)),
            ("empty", Data()),
            ("oversized", oversized),
            ("missing waiting", Data(#"{"type":"push_detail","item_ref":"item-1"}"#.utf8)),
        ]
        for (label, data) in answers {
            let clock = makeClock()
            let transport = FakeDetailTransport(.reply(data, after: 0), clock: clock)
            let detail = await PushDetailFetcher(transport: transport, clock: clock).fetch(itemRef: "item-1")
            XCTAssertNil(detail, label)
        }
    }
}
