import XCTest
import AppKit

// AppControlProtocol is compiled into this target directly (logic test).

final class AppControlProtocolTests: XCTestCase {

    func testParsesACommandAndItsArguments() throws {
        let req = try AppControlRequest.parse(#"{"cmd":"click","window":1,"x":12.5,"y":30,"modifiers":["cmd"]}"#).get()
        XCTAssertEqual(req.cmd, "click")
        XCTAssertEqual(req.int("window"), 1)
        XCTAssertEqual(req.double("x"), 12.5)
        XCTAssertEqual(req.strings("modifiers"), ["cmd"])
    }

    func testRejectsNonJSONAndMissingCmd() {
        XCTAssertThrowsError(try AppControlRequest.parse("click please").get())
        XCTAssertThrowsError(try AppControlRequest.parse(#"{"window":0}"#).get())
        XCTAssertThrowsError(try AppControlRequest.parse(#"{"cmd":""}"#).get())
    }

    func testTopLeftPointConvertsToWindowCoordinates() {
        // 40pt below the top of a 800pt-tall content area is y=760 in AppKit.
        XCTAssertEqual(AppControlGeometry.windowPoint(x: 10, y: 40, contentHeight: 800), NSPoint(x: 10, y: 760))
    }

    func testViewFrameConvertsToTopLeftRect() {
        let r = AppControlGeometry.topLeftRect(viewFrameInWindow: NSRect(x: 5, y: 700, width: 100, height: 50), contentHeight: 800)
        XCTAssertEqual(r, ["x": 5, "y": 50, "w": 100, "h": 50])
    }

    func testModifierNames() {
        XCTAssertEqual(AppControlGeometry.modifiers(["cmd", "Shift", "opt", "ctrl", "bogus"]),
                       [.command, .shift, .option, .control])
        XCTAssertTrue(AppControlGeometry.modifiers([]).isEmpty)
    }

    func testWireEnvelopes() throws {
        let ok = try JSONSerialization.jsonObject(with: Data(AppControlWire.ok(["a": 1]).utf8)) as! [String: Any]
        XCTAssertEqual(ok["ok"] as? Bool, true)
        let bad = try JSONSerialization.jsonObject(with: Data(AppControlWire.fail(.noSuchWindow(3)).utf8)) as! [String: Any]
        XCTAssertEqual(bad["ok"] as? Bool, false)
        XCTAssertEqual(bad["error"] as? String, "no window with index 3")
    }
}
