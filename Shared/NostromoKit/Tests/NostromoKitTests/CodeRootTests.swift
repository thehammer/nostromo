import XCTest
@testable import NostromoKit

/// The app and the daemon must resolve the code root identically (src/config.rs `resolve_code_root`).
final class CodeRootTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me")

    private func resolve(env: [String: String] = [:], toml: String? = nil) -> String {
        CodeRoot.resolve(env: env, home: home, configText: toml ?? "").path
    }

    func testDefaultsToHomeCodeSoExistingSetupsAreUnchanged() {
        XCTAssertEqual(resolve(), "/Users/me/Code")
    }

    func testConfigOverridesDefault() {
        XCTAssertEqual(resolve(toml: "code_root = \"/work/src\""), "/work/src")
    }

    func testEnvOverridesConfig() {
        XCTAssertEqual(resolve(env: ["NOSTROMO_CODE_ROOT": "/env"], toml: "code_root = \"/work/src\""), "/env")
    }

    func testEmptyValuesFallThrough() {
        XCTAssertEqual(resolve(env: ["NOSTROMO_CODE_ROOT": ""], toml: "code_root = \"\""), "/Users/me/Code")
    }

    func testTildeExpands() {
        XCTAssertEqual(resolve(toml: "code_root = \"~/Software Development\""), "/Users/me/Software Development")
    }

    func testIgnoresOtherKeysCommentsAndTables() {
        let toml = """
        # code_root = "/commented"
        tcp_addr = "127.0.0.1:1"
        code_root = '~/lit'
        [other]
        code_root = "/in-table"
        """
        XCTAssertEqual(resolve(toml: toml), "/Users/me/lit")
        XCTAssertEqual(resolve(toml: "[other]\ncode_root = \"/in-table\""), "/Users/me/Code")
    }
}
