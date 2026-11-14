import XCTest

final class NewSessionCopyTests: XCTestCase {
    func testTheConfirmationSaysTheConversationMovesToHistory() {
        let text = ReplView.newSessionInformativeText
        XCTAssertEqual(text, "The current conversation moves to History. You can resume it from New Focus \u{203A} Resume.")
        XCTAssertFalse(text.contains("will be lost"))
        XCTAssertFalse(text.lowercased().contains("memory"))
    }
}
