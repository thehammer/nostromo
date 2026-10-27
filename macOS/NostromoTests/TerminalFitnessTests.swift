import XCTest
import AppKit

// Fitness checks for the terminal pane (1d). Most of these read source text and the project file,
// because the rules they pin are about what is allowed to depend on what, and about every path that
// can send bytes to a shell asking the input guard first. None of them needs a running view.
//
//   T5  SwiftTerm is imported only by `NostromoTerminalView` and `TerminalPaneHostView`, is a
//       dependency of the app target alone, and no test source (or app file the tests compile) imports it.
//   -   Every input path in `UI/Terminal` asks `TerminalInputGuard`.
//   -   The files this slice added exist and are built into the right targets.
//   -   The project file's new object ids are well formed.
//   -   The main menu has the Terminal menu, Find items and the latency item.

// MARK: - Repository and project-file helpers

private enum Repo {
    /// `<repo>`: this file is `<repo>/macOS/NostromoTests/TerminalFitnessTests.swift`.
    static func root(file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url
    }

    static var macOS: URL { root().appendingPathComponent("macOS") }
    static var app: URL { macOS.appendingPathComponent("Nostromo") }
    static var tests: URL { macOS.appendingPathComponent("NostromoTests") }
    static var pbxproj: URL { macOS.appendingPathComponent("Nostromo.xcodeproj/project.pbxproj") }

    static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// Every `.swift` file under `directory`, recursively.
    static func swiftFiles(under directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Lines that are code: not blank and not a comment.
    static func codeLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("//")
        }
    }

    static func firstMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).map { match in
            (0..<match.numberOfRanges).map { i in
                Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    /// True when a code line imports SwiftTerm (comments and strings that merely mention it do not count).
    static func importsSwiftTerm(_ text: String) -> Bool {
        !matches(#"(?m)^[ \t]*(@\w+[ \t]+)?import[ \t]+(struct[ \t]+|class[ \t]+)?SwiftTerm\b"#, in: text).isEmpty
    }
}

/// Just enough of `project.pbxproj` to ask which files a Sources phase builds.
private struct Project {
    static let appTarget = "AA0000000000000000000040"
    static let testTarget = "BB00000000000000000000D1"
    static let appSources = "AA0000000000000000000030"
    static let testSources = "BB00000000000000000000D2"

    let text: String
    let lines: [String]
    /// file reference id -> its `path`
    let filePath: [String: String]
    /// build file id -> file reference id
    let buildFileRef: [String: String]

    init() throws {
        text = try Repo.read(Repo.pbxproj)
        lines = text.components(separatedBy: "\n")
        var paths: [String: String] = [:]
        for m in Repo.matches(#"(?m)^\t\t(\w+) /\*.*?\*/ = \{isa = PBXFileReference;.*? path = ("[^"]+"|[^;]+);"#, in: text) {
            paths[m[1]] = m[2].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        filePath = paths
        var refs: [String: String] = [:]
        for m in Repo.matches(#"(?m)^\t\t(\w+) /\*.*?\*/ = \{isa = PBXBuildFile; fileRef = (\w+)"#, in: text) {
            refs[m[1]] = m[2]
        }
        buildFileRef = refs
    }

    /// The object `id` as text: from its `\t\t<id> /* ... */ = {` line to the closing `\t\t};`.
    func objectText(_ id: String) -> String? {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("\t\t\(id) /*") && $0.hasSuffix("= {") }) else { return nil }
        var out: [String] = []
        for line in lines[start...] {
            out.append(line)
            if line == "\t\t};" { break }
        }
        return out.joined(separator: "\n")
    }

    /// The entries of the `<key> = ( ... );` list inside `object`.
    func list(_ key: String, in object: String) -> [String] {
        var inside = false
        var out: [String] = []
        for line in object.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !inside {
                if trimmed == "\(key) = (" { inside = true }
            } else if trimmed == ");" {
                break
            } else {
                out.append(trimmed)
            }
        }
        return out
    }

    /// The file names a Sources build phase compiles.
    func fileNames(inPhase phase: String) -> Set<String> {
        guard let object = objectText(phase) else { return [] }
        var names: Set<String> = []
        for entry in list("files", in: object) {
            guard let id = Repo.firstMatch(#"^(\w+) /\*"#, in: entry)?[1],
                  let ref = buildFileRef[id], let path = filePath[ref] else { continue }
            names.insert((path as NSString).lastPathComponent)
        }
        return names
    }

    var appFiles: Set<String> { fileNames(inPhase: Project.appSources) }
    var testFiles: Set<String> { fileNames(inPhase: Project.testSources) }
}

// MARK: - Tests

final class TerminalFitnessTests: XCTestCase {

    private let swiftTermViews: Set<String> = ["NostromoTerminalView.swift", "TerminalPaneHostView.swift"]

    // MARK: T5: where SwiftTerm may be imported

    func testNoTestSourceImportsSwiftTerm() throws {
        let files = Repo.swiftFiles(under: Repo.tests)
        XCTAssertGreaterThan(files.count, 50, "the test directory should be found")
        for file in files {
            XCTAssertFalse(Repo.importsSwiftTerm(try Repo.read(file)),
                           "\(file.lastPathComponent) imports SwiftTerm; the test target must not depend on it")
        }
    }

    func testNoAppFileCompiledIntoTheTestTargetImportsSwiftTerm() throws {
        let project = try Project()
        let testBuilt = project.testFiles
        XCTAssertGreaterThan(testBuilt.count, 50, "the test target's Sources phase should be found")

        var byName: [String: [URL]] = [:]
        for url in Repo.swiftFiles(under: Repo.app) { byName[url.lastPathComponent, default: []].append(url) }

        var checked = 0
        for name in testBuilt.sorted() {
            for url in byName[name] ?? [] {
                checked += 1
                XCTAssertFalse(Repo.importsSwiftTerm(try Repo.read(url)),
                               "\(name) is compiled into the test target and must not use SwiftTerm")
            }
        }
        XCTAssertGreaterThan(checked, 20, "app sources compiled into the tests should have been resolved")
        XCTAssertTrue(testBuilt.isDisjoint(with: swiftTermViews),
                      "the SwiftTerm views must not be compiled into the test target")
    }

    func testOnlyTheTwoTerminalViewFilesImportSwiftTerm() throws {
        var importers: Set<String> = []
        for url in Repo.swiftFiles(under: Repo.app) {
            if Repo.importsSwiftTerm(try Repo.read(url)) { importers.insert(url.lastPathComponent) }
        }
        XCTAssertEqual(importers, swiftTermViews)
    }

    func testSwiftTermIsADependencyOfTheAppTargetOnly() throws {
        let project = try Project()
        let app = try XCTUnwrap(project.objectText(Project.appTarget), "app target not found")
        let tests = try XCTUnwrap(project.objectText(Project.testTarget), "test target not found")

        let appDependencies = project.list("packageProductDependencies", in: app)
        let swiftTermEntry = try XCTUnwrap(appDependencies.first { $0.contains("/* SwiftTerm */") },
                                           "the app target does not list SwiftTerm: \(appDependencies)")
        let productId = try XCTUnwrap(Repo.firstMatch(#"^(\w+) /\*"#, in: swiftTermEntry)?[1])

        let testDependencies = project.list("packageProductDependencies", in: tests)
        XCTAssertFalse(testDependencies.contains { $0.contains("SwiftTerm") || $0.hasPrefix(productId) },
                       "the test target must not depend on SwiftTerm: \(testDependencies)")

        // The test target's own link phase must not carry it either.
        for phase in project.list("buildPhases", in: tests) {
            guard let phaseId = Repo.firstMatch(#"^(\w+) /\*"#, in: phase)?[1],
                  let object = project.objectText(phaseId) else { continue }
            XCTAssertFalse(object.contains("SwiftTerm") || object.contains(productId),
                           "the test target's build phase \(phase) references SwiftTerm")
        }
    }

    func testSwiftTermIsPinnedToExactlyVersion1_18_0() throws {
        let project = try Project()
        let block = try XCTUnwrap(
            Repo.firstMatch(#"(?s)isa = XCRemoteSwiftPackageReference;\s*repositoryURL = "https://github\.com/migueldeicaza/SwiftTerm";\s*requirement = \{(.*?)\};"#,
                            in: project.text)?[1],
            "no remote package reference for https://github.com/migueldeicaza/SwiftTerm")
        XCTAssertTrue(block.contains("kind = exactVersion;"), block)
        XCTAssertTrue(block.contains("version = 1.18.0;"), block)

        let resolved = Repo.macOS.appendingPathComponent("Nostromo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        let data = try Data(contentsOf: resolved)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try XCTUnwrap(json["pins"] as? [[String: Any]])
        let pin = try XCTUnwrap(pins.first { ($0["identity"] as? String)?.lowercased() == "swiftterm" },
                                "Package.resolved has no swiftterm pin")
        let state = try XCTUnwrap(pin["state"] as? [String: Any])
        XCTAssertEqual(state["version"] as? String, "1.18.0")
    }

    // MARK: Routing

    func testDynamicFocusViewRoutesTerminalPanesToTheTerminalHost() throws {
        let source = try Repo.read(Repo.app.appendingPathComponent("UI/Views/DynamicFocusView.swift"))
        let routing = try XCTUnwrap(source.range(of: #"paneId.hasPrefix("terminal-")"#),
                                    "makeLeafView has no branch for terminal- panes")
        let before = source[..<routing.lowerBound]
        XCTAssertTrue(before.contains("func makeLeafView"), "the terminal branch should be inside makeLeafView")

        let after = source[routing.upperBound...]
        let branchEnd = after.range(of: "} else")?.lowerBound ?? after.endIndex
        XCTAssertTrue(after[..<branchEnd].contains("terminalPaneFactory"),
                      "a terminal- pane must be built through DynamicFocusView.terminalPaneFactory (the test bundle compiles this file and cannot link the SwiftTerm view)")
        // ...and the app points the factory at the real host view.
        let delegate = try Repo.read(Repo.app.appendingPathComponent("AppDelegate.swift"))
        let wiring = try XCTUnwrap(delegate.range(of: "DynamicFocusView.terminalPaneFactory"),
                                   "AppDelegate never sets the terminal pane factory")
        XCTAssertTrue(delegate[wiring.upperBound...].prefix(300).contains("TerminalPaneHostView("),
                      "the factory must build a TerminalPaneHostView")
    }

    // MARK: Every input path asks the guard

    private struct Declaration {
        let file: String
        let header: String
        let body: String
    }

    /// Every func in `lines` that matches `include`, with its body: from its line up to the next
    /// `func` or `@objc` line.
    private func declarations(in file: String, lines: [String], include: (_ index: Int) -> Bool) -> [Declaration] {
        func isBoundary(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("@objc") || t.contains("func ")
        }
        var found: [Declaration] = []
        for i in lines.indices where include(i) {
            // The func itself may be on the line after a lone `@objc`.
            guard let j = (i...min(i + 2, lines.count - 1)).first(where: { lines[$0].contains("func ") }) else { continue }
            let end = ((j + 1)..<lines.count).first(where: { isBoundary(lines[$0]) }) ?? lines.count
            found.append(Declaration(file: file,
                                     header: lines[j].trimmingCharacters(in: .whitespaces),
                                     body: lines[j..<end].joined(separator: "\n")))
        }
        return found
    }

    private func terminalViewSources() throws -> [(name: String, lines: [String])] {
        let dir = Repo.app.appendingPathComponent("UI/Terminal")
        let files = Repo.swiftFiles(under: dir)
        XCTAssertGreaterThan(files.count, 5, "UI/Terminal should be found")
        var sources: [(name: String, lines: [String])] = []
        for file in files { sources.append((name: file.lastPathComponent, lines: Repo.codeLines(try Repo.read(file)))) }
        return sources
    }

    /// Actions that need no input-guard check because none of them can open, change or write to a terminal:
    ///  - `cancelTapped`, `dismissTapped`, `okTapped`: close a sheet; they answer nothing that connects.
    ///  - `copyTapped`: copies the failure text to the pasteboard.
    ///  - `submitTapped`: only asks the daemon to show the confirm sheet; the connection itself still
    ///    needs the human's Connect click (`connectTapped`, which is NOT exempt).
    ///  - `popupChanged`, `projectChanged`, `environmentChanged`, `serviceChanged`, `shellTypeChanged`:
    ///    picker popups that change a form selection only.
    /// Every other action, `connectTapped` included, must ask `TerminalInputGuard`.
    private let guardExemptActions: [String] = [
        "cancelTapped", "dismissTapped", "okTapped", "copyTapped", "submitTapped",
        "popupChanged", "projectChanged", "environmentChanged", "serviceChanged", "shellTypeChanged",
    ]

    func testEveryObjcActionInTheTerminalViewsAsksTheInputGuard() throws {
        var actions: [Declaration] = []
        for source in try terminalViewSources() {
            actions += declarations(in: source.name, lines: source.lines) { i in
                let line = source.lines[i].trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("@objc") else { return false }
                return !line.contains(" protocol ") && !line.contains(" class ") && !line.contains(" enum ")
            }
        }
        XCTAssertGreaterThanOrEqual(actions.count, 3, "the host's close/overlay-close/restart actions should be found")
        for action in actions {
            if guardExemptActions.contains(where: { action.header.contains("func \($0)(") }) { continue }
            XCTAssertTrue(action.body.contains("TerminalInputGuard."),
                          "\(action.file): `\(action.header)` is an action that changes a terminal and must ask TerminalInputGuard first")
        }
    }

    func testEveryPathThatSendsBytesAsksTheInputGuard() throws {
        let entryPoints = ["func send(source", "func insertText(", "func paste("]
        var found: [Declaration] = []
        for source in try terminalViewSources() {
            found += declarations(in: source.name, lines: source.lines) { i in
                entryPoints.contains { source.lines[i].contains($0) }
            }
        }
        for entry in entryPoints {
            XCTAssertTrue(found.contains { $0.header.contains(entry) }, "no `\(entry)` found in UI/Terminal")
        }
        for decl in found {
            XCTAssertTrue(decl.body.contains("TerminalInputGuard."),
                          "\(decl.file): `\(decl.header)` sends or accepts input and must ask TerminalInputGuard first")
        }
    }

    func testTheMenuCloseActionAsksTheInputGuard() throws {
        let host = try XCTUnwrap(try terminalViewSources().first { $0.name == "TerminalPaneHostView.swift" })
        let close = declarations(in: host.name, lines: host.lines) { host.lines[$0].contains("func closeFromMenu") }
        let decl = try XCTUnwrap(close.first, "TerminalPaneHostView.closeFromMenu not found")
        XCTAssertTrue(decl.body.contains("TerminalInputGuard."), "closeFromMenu must ask TerminalInputGuard first")
    }

    // MARK: The emulator's own replies are not typing

    private func terminalViewSource(_ name: String) throws -> (name: String, lines: [String]) {
        try XCTUnwrap(try terminalViewSources().first { $0.name == name }, "\(name) not found in UI/Terminal")
    }

    func testTheViewOverridesTheEmulatorReplyRouteAndMarksItAsAnEmulatorReply() throws {
        let view = try terminalViewSource("NostromoTerminalView.swift")
        let replyRoute = declarations(in: view.name, lines: view.lines) {
            view.lines[$0].contains("override func send(source: Terminal,")
        }
        let decl = try XCTUnwrap(replyRoute.first,
                                 "NostromoTerminalView must override `func send(source: Terminal, data:)`, the route SwiftTerm uses for the emulator's own answers")
        XCTAssertNotNil(Repo.firstMatch(#"TerminalInputGuard\.verdict\(origin:\s*\.emulatorReply"#, in: decl.body),
                        "the emulator reply route must ask the guard with origin .emulatorReply:\n\(decl.body)")
        XCTAssertTrue(decl.body.contains("emulatorReplyDepth"),
                      "the reply route must mark the bytes it makes as replies (emulatorReplyDepth) for the delegate")
    }

    func testTheDelegateSendDecidesTheOriginFromTheReplyMarkerNotFromTheCurrentEvent() throws {
        let view = try terminalViewSource("NostromoTerminalView.swift")
        let delegate = declarations(in: view.name, lines: view.lines) {
            view.lines[$0].contains("func send(source: TerminalView")
        }
        let decl = try XCTUnwrap(delegate.first, "the TerminalViewDelegate `send(source: TerminalView, data:)` not found")
        XCTAssertTrue(decl.body.contains("emulatorReplyDepth"),
                      "the delegate send must read emulatorReplyDepth to tell a reply from typing:\n\(decl.body)")
        XCTAssertTrue(decl.body.contains("TerminalInputGuard.verdict("), "the delegate send must ask the guard")
        XCTAssertTrue(decl.body.contains("autoReply: true"), "a reply must be sent marked autoReply")
    }

    func testTypedPathsAskTheGuardWithTheTypedOrigin() throws {
        let view = try terminalViewSource("NostromoTerminalView.swift")
        for entry in ["func insertText(", "func paste("] {
            let found = declarations(in: view.name, lines: view.lines) { view.lines[$0].contains(entry) }
            let decl = try XCTUnwrap(found.first, "`\(entry)` not found in NostromoTerminalView")
            XCTAssertNotNil(Repo.firstMatch(#"TerminalInputGuard\.verdict\(origin:\s*\.typed"#, in: decl.body),
                            "`\(entry)` is a person's input and must ask the guard with origin .typed")
        }
    }

    // MARK: A terminal's screen is not readable through app-control's accessibility walk

    func testTheTerminalViewsAccessibilityValueGoesThroughTheScreenAccessGate() throws {
        let view = try terminalViewSource("NostromoTerminalView.swift")
        let found = declarations(in: view.name, lines: view.lines) { view.lines[$0].contains("func accessibilityValue") }
        let decl = try XCTUnwrap(found.first, "NostromoTerminalView does not override accessibilityValue")
        let call = try XCTUnwrap(decl.body.range(of: "TerminalScreenAccess.accessibilityValue("),
                                 "accessibilityValue must call TerminalScreenAccess.accessibilityValue(...):\n\(decl.body)")
        XCTAssertNil(Repo.firstMatch(#"return\s+(self\.)?screenText\("#, in: decl.body),
                     "accessibilityValue must not return the screen text directly:\n\(decl.body)")
        if let direct = decl.body.range(of: "screenText(") {
            XCTAssertGreaterThan(direct.lowerBound, call.lowerBound,
                                 "screenText( may only appear inside the gate's closure:\n\(decl.body)")
        }
        // Whatever the override returns, it is not a bare string.
        XCTAssertFalse(decl.body.contains("return screenText"), decl.body)
    }

    func testAppControlReadsAccessibilityOnlyThroughAppControlAX() throws {
        let server = try Repo.read(Repo.app.appendingPathComponent("AppControl/AppControlServer.swift"))
        let code = Repo.codeLines(server).joined(separator: "\n")
        XCTAssertFalse(code.contains("accessibilityValue"),
                       "AppControlServer must not read accessibility values itself; AppControlAX is the one reader (and the one the tests cover)")
        XCTAssertTrue(code.contains("AppControlAX.hits("), "tree and find walk hosting views through AppControlAX.hits")
        XCTAssertTrue(code.contains("AppControlAX.dump("), "ax dumps through AppControlAX.dump")
    }

    // MARK: Scaffold files exist and are built into the right targets

    private func assertBuilt(_ files: [String], underApp: Bool, inApp: Bool, inTests: Bool,
                             project: Project, line: UInt = #line) {
        let root = underApp ? Repo.app : Repo.tests
        for relative in files {
            let name = (relative as NSString).lastPathComponent
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(relative).path),
                          "\(relative) does not exist on disk", line: line)
            XCTAssertEqual(project.appFiles.contains(name), inApp,
                           "\(name) should\(inApp ? "" : " not") be in the app target's Sources", line: line)
            XCTAssertEqual(project.testFiles.contains(name), inTests,
                           "\(name) should\(inTests ? "" : " not") be in the test target's Sources", line: line)
        }
    }

    func testFilesThatAreBuiltIntoBothTheAppAndTheTests() throws {
        assertBuilt(["Data/TerminalWire.swift", "Data/TerminalSessionStore.swift", "Data/TerminalLatencyStats.swift",
                     "UI/Terminal/TerminalInputGuard.swift",
                     "Data/RemoteShellWire.swift", "Data/RemoteShellStore.swift", "UI/Toast/ToastAction.swift",
                     "UI/Terminal/TerminalChromeModel.swift", "UI/Terminal/IdleCountdownModel.swift",
                     "UI/Terminal/PastePolicy.swift", "UI/Terminal/FollowModel.swift", "Data/TurnOrigin.swift",
                     "AppControl/AppControlAX.swift"],
                    underApp: true, inApp: true, inTests: true, project: try Project())
    }

    func testFilesThatAreBuiltIntoTheAppOnly() throws {
        assertBuilt(["UI/Terminal/NostromoTerminalView.swift", "UI/Terminal/TerminalPaneHostView.swift",
                     "UI/Terminal/RemoteShellConfirmSheet.swift", "UI/Terminal/RemoteShellPresenter.swift",
                     "UI/Terminal/NewRemoteShellSheet.swift", "UI/Terminal/RemoteShellFailureSheet.swift",
                     "UI/Terminal/PasteConfirmSheet.swift", "UI/Terminal/FollowControlView.swift",
                     "UI/Views/TerminalDeliveryBlockView.swift"],
                    underApp: true, inApp: true, inTests: false, project: try Project())
    }

    func testTestFilesAreBuiltIntoTheTestTargetOnly() throws {
        assertBuilt(["TerminalWireTests.swift", "TerminalSessionStoreTests.swift", "TerminalInputGuardTests.swift",
                     "TerminalLatencyStatsTests.swift", "TerminalFitnessTests.swift",
                     "RemoteShellStoreTests.swift", "RemoteShellWireTests.swift", "ProjectDetectionTests.swift",
                     "TerminalChromeModelTests.swift", "IdleCountdownModelTests.swift", "PastePolicyTests.swift",
                     "TerminalStoreMirrorTests.swift", "FollowModelTests.swift", "TurnOriginTests.swift",
                     "TerminalScreenAccessTests.swift"],
                    underApp: false, inApp: false, inTests: true, project: try Project())
    }

    // MARK: New project-file ids

    func testEveryNewProjectIdIsUniqueAndTwentyFourCharacters() throws {
        let project = try Project()

        let tokens = Repo.matches(#"\bTP0000[A-Za-z0-9]*\b"#, in: project.text).map { $0[0] }
        XCTAssertGreaterThan(tokens.count, 100, "the slice's ids should be found")
        for token in Set(tokens) {
            XCTAssertEqual(token.count, 24, "\(token) is not 24 characters long")
        }

        // An id may be mentioned many times; it may be defined once.
        let definitions = Repo.matches(#"(?m)^\t\t(TP0000\w*) /\*.*?\*/ = \{"#, in: project.text).map { $0[1] }
        XCTAssertFalse(definitions.isEmpty)
        XCTAssertEqual(definitions.count, Set(definitions).count,
                       "an id is defined twice: \(Dictionary(grouping: definitions, by: { $0 }).filter { $1.count > 1 }.keys.sorted())")
    }

    // MARK: Main menu

    private func topLevelMenu(_ title: String, in menu: NSMenu) -> (index: Int, menu: NSMenu)? {
        for (i, item) in menu.items.enumerated() where item.submenu?.title == title {
            return (i, item.submenu!)
        }
        return nil
    }

    private func item(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    func testTheTerminalMenuFollowsEditAndHasNewTerminalAndCloseTerminalPane() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let edit = try XCTUnwrap(topLevelMenu("Edit", in: main))
        let terminal = try XCTUnwrap(topLevelMenu("Terminal", in: main), "no top-level Terminal menu")
        XCTAssertEqual(terminal.index, edit.index + 1, "Terminal comes right after Edit")

        let new = try XCTUnwrap(item("New Terminal", in: terminal.menu))
        XCTAssertEqual(new.keyEquivalent, "t")
        XCTAssertEqual(new.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command])

        let close = try XCTUnwrap(item("Close Terminal Pane", in: terminal.menu))
        XCTAssertEqual(close.keyEquivalent.lowercased(), "w")
        XCTAssertEqual(close.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command, .shift])
    }

    func testEditHasFindAndFindNextThatTheAppDelegateRoutesToATerminalPane() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let edit = try XCTUnwrap(topLevelMenu("Edit", in: main)).menu
        // Not `performFindPanelAction:`: an NSTextView (the REPL) would answer that and open a find panel.
        let action = #selector(MainMenuActions.terminalFind(_:))

        let find = try XCTUnwrap(item("Find\u{2026}", in: edit), "Edit has no Find\u{2026}")
        XCTAssertEqual(find.keyEquivalent, "f")
        XCTAssertEqual(find.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command])
        XCTAssertEqual(find.action, action)
        XCTAssertEqual(find.tag, NSTextFinder.Action.showFindInterface.rawValue)

        let next = try XCTUnwrap(item("Find Next", in: edit), "Edit has no Find Next")
        XCTAssertEqual(next.keyEquivalent, "g")
        XCTAssertEqual(next.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command])
        XCTAssertEqual(next.action, action)
        XCTAssertEqual(next.tag, NSTextFinder.Action.nextMatch.rawValue)
    }

    func testDebugHasCopyTerminalLatencyStatsWithNoKeyEquivalent() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let debug = try XCTUnwrap(topLevelMenu("Debug", in: main)).menu

        let latency = try XCTUnwrap(item("Copy terminal latency stats", in: debug))
        XCTAssertEqual(latency.keyEquivalent, "")
    }

    func testTheNewKeyEquivalentsDoNotCollideWithAnotherMenuItem() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)

        struct Chord: Hashable { let key: String; let mask: UInt }
        var owners: [Chord: [String]] = [:]
        for top in main.items {
            for entry in top.submenu?.items ?? [] where !entry.keyEquivalent.isEmpty {
                let mask = entry.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                owners[Chord(key: entry.keyEquivalent.lowercased(), mask: mask.rawValue), default: []].append(entry.title)
            }
        }
        let command = NSEvent.ModifierFlags.command
        let commandShift: NSEvent.ModifierFlags = [.command, .shift]
        for chord in [Chord(key: "t", mask: command.rawValue), Chord(key: "w", mask: commandShift.rawValue),
                      Chord(key: "f", mask: command.rawValue), Chord(key: "g", mask: command.rawValue)] {
            XCTAssertEqual(owners[chord]?.count, 1, "\(chord.key) is claimed by \(owners[chord] ?? [])")
        }
    }

    // MARK: Remote shell confirm sheet (2c)

    private func confirmSheetCode() throws -> String {
        let url = Repo.app.appendingPathComponent("UI/Terminal/RemoteShellConfirmSheet.swift")
        return Repo.codeLines(try Repo.read(url)).joined(separator: "\n")
    }

    func testTheConfirmSheetHasCancelAndConnectButtons() throws {
        let code = try confirmSheetCode()
        XCTAssertTrue(code.contains("cancelButton"))
        XCTAssertTrue(code.contains("connectButton"))
    }

    func testConnectIsAKeyViewButtonSubclassSoTabReachesIt() throws {
        let code = try confirmSheetCode()
        XCTAssertNotNil(Repo.firstMatch(#"(?s)final class ConnectButton:\s*NSButton.*?override var canBecomeKeyView:\s*Bool\s*\{\s*(return\s+)?true\b"#, in: code),
                        "ConnectButton must be a final NSButton subclass whose canBecomeKeyView is true")
        XCTAssertNotNil(Repo.firstMatch(#"connectButton\s*(:[^=\n]*)?=\s*ConnectButton\("#, in: code),
                        "connectButton must be a ConnectButton")
    }

    func testReturnIsCancelAndConnectNeverHasAKeyEquivalent() throws {
        let code = try confirmSheetCode()
        XCTAssertTrue(code.contains(#"cancelButton.keyEquivalent = "\r""#), "Return must trigger Cancel")
        XCTAssertFalse(code.contains("connectButton.keyEquivalent"), "Connect must never have a key equivalent")
        let lines = code.components(separatedBy: "\n")
        for line in lines where line.contains("keyEquivalent") {
            XCTAssertFalse(line.contains("connectTapped") || line.contains("connectButton"), line)
            XCTAssertTrue(line.contains("cancelButton") || line.contains(#"\u{1b}"#) || line.contains("cancel"),
                          "only Cancel (Return) and the hidden Escape path may set a keyEquivalent: \(line)")
        }
    }

    func testEscapeIsASecondPathToCancel() throws {
        let code = try confirmSheetCode()
        let lines = code.components(separatedBy: "\n")
        XCTAssertTrue(code.contains("cancelOperation") || code.contains(#""\u{1b}""#),
                      "the sheet needs a hidden Escape path")
        if let cancelOp = lines.firstIndex(where: { $0.contains("cancelOperation") }) {
            let window = lines[cancelOp..<min(cancelOp + 6, lines.count)].joined(separator: "\n")
            XCTAssertTrue(window.lowercased().contains("cancel"), "Escape (cancelOperation) must cancel:\n\(window)")
        } else if let esc = lines.firstIndex(where: { $0.contains(#""\u{1b}""#) }) {
            let window = lines[max(0, esc - 4)..<min(esc + 5, lines.count)].joined(separator: "\n")
            XCTAssertTrue(window.contains("cancelTapped") || window.contains("cancelButton"),
                          "the Escape key equivalent must target Cancel:\n\(window)")
        }
    }

    func testConnectTappedAsksTheInputGuardAndReportsARefusal() throws {
        let url = Repo.app.appendingPathComponent("UI/Terminal/RemoteShellConfirmSheet.swift")
        let lines = Repo.codeLines(try Repo.read(url))
        let found = declarations(in: url.lastPathComponent, lines: lines) { lines[$0].contains("func connectTapped(") }
        let decl = try XCTUnwrap(found.first, "connectTapped not found")
        XCTAssertTrue(decl.header.contains("connectTapped("))
        XCTAssertTrue(decl.body.contains("TerminalInputGuard.allowsControl("),
                      "connectTapped must ask the input guard:\n\(decl.body)")
        XCTAssertTrue(decl.body.contains("reportRefusal"), "a refused Connect must be reported:\n\(decl.body)")
        XCTAssertTrue(decl.body.contains("connect"), decl.body)
    }

    func testOnlyTheConfirmSheetEverSendsAConnectDecision() throws {
        var sawSheet = false
        for url in Repo.swiftFiles(under: Repo.app) {
            let code = Repo.codeLines(try Repo.read(url)).joined(separator: "\n")
            if url.lastPathComponent == "RemoteShellConfirmSheet.swift" {
                sawSheet = true
                XCTAssertTrue(code.contains("decision: .connect"), "the sheet's Connect sends the connect decision")
            } else {
                XCTAssertFalse(code.contains("decision: .connect"),
                               "\(url.lastPathComponent) sends a connect decision; only RemoteShellConfirmSheet's Connect button may")
            }
        }
        XCTAssertTrue(sawSheet)
    }

    // The confirm sheet shows what will run (review fix-ups for PR #359): nothing the person has to
    // decide on may be cut off, the details are selectable, and Connect is off when the daemon did not
    // say what will run.

    /// The variable a label is assigned to, found by its accessibility identifier.
    private func variable(withId id: String, in code: String) -> String? {
        Repo.firstMatch(#"(\w+)\.setAccessibilityIdentifier\(""# + NSRegularExpression.escapedPattern(for: id) + #""\)"#,
                        in: code)?[1]
    }

    func testTheConfirmSheetNeverTruncatesOrClipsAnything() throws {
        let code = try confirmSheetCode()
        for mode in [".byTruncatingTail", ".byTruncatingMiddle", ".byTruncatingHead", ".byClipping"] {
            XCTAssertFalse(code.contains(mode), "the sheet must show everything it says; found \(mode)")
        }
    }

    func testTheTitleAndSubtitleWrapOnAnyNumberOfLines() throws {
        let code = try confirmSheetCode()
        for id in ["remote-shell-title", "remote-shell-target"] {
            let name = try XCTUnwrap(variable(withId: id, in: code), "no label with id \(id)")
            XCTAssertNotNil(Repo.firstMatch(#"\b"# + name + #"\.maximumNumberOfLines\s*=\s*0\b"#, in: code),
                            "\(id) must set maximumNumberOfLines = 0")
            XCTAssertNotNil(Repo.firstMatch(#"\b"# + name + #"\s*(:[^=\n]*)?=\s*NSTextField\(wrappingLabelWithString"#, in: code)
                            ?? Repo.firstMatch(#"\b"# + name + #"\.lineBreakMode\s*=\s*\.by(Word|Char)Wrapping"#, in: code),
                            "\(id) must be a wrapping label")
        }
    }

    func testTheSubtitleCanBeSqueezedHorizontallySoItWrapsInsteadOfWideningTheSheet() throws {
        let code = try confirmSheetCode()
        let name = try XCTUnwrap(variable(withId: "remote-shell-target", in: code))
        XCTAssertNotNil(
            Repo.firstMatch(#"\b"# + name + #"\.setContentCompressionResistancePriority\(\s*(\.defaultLow|\.fittingSizeCompression|NSLayoutConstraint\.Priority\(\s*(\d{1,2}|1\d\d|2[0-4]\d|250)(\.0)?\s*\))\s*,\s*for:\s*\.horizontal"#,
                            in: code),
            "the subtitle needs a horizontal compression resistance of .defaultLow or lower")
    }

    func testTheSheetShowsTheDetailsInASelectableMonospacedCappedScrollingBlock() throws {
        let code = try confirmSheetCode()
        XCTAssertTrue(code.contains("model.details"), "the sheet must render model.details")
        XCTAssertTrue(code.contains(#""remote-shell-details""#), "the details block needs the id remote-shell-details")
        XCTAssertTrue(code.contains("isSelectable = true"), "the details must be selectable (copyable)")
        XCTAssertTrue(code.contains("monospacedSystemFont"), "the details must be monospaced")
        XCTAssertTrue(code.contains("NSScrollView"), "the details sit in a scroll view")
        XCTAssertTrue(code.contains("maxDetailsHeight"), "the scroll view's height must be capped by maxDetailsHeight")
        XCTAssertTrue(code.contains(".byCharWrapping"), "an unbroken command must wrap by character")
    }

    func testTheReasonHasItsOwnLabelUnderAnUnverifiedHeading() throws {
        let code = try confirmSheetCode()
        XCTAssertTrue(code.contains("Agent's stated reason (unverified)"), "the heading text")
        let heading = try XCTUnwrap(variable(withId: "remote-shell-reason-heading", in: code))
        let reason = try XCTUnwrap(variable(withId: "remote-shell-reason", in: code))
        let requester = try XCTUnwrap(variable(withId: "remote-shell-requester", in: code))
        XCTAssertEqual(Set([heading, reason, requester]).count, 3, "heading, reason and requester are three labels")
        XCTAssertTrue(code.contains("model.reason"), "the reason label shows model.reason")
        XCTAssertTrue(code.contains("model.requestedBy"), "the requester label shows model.requestedBy")
        XCTAssertFalse(code.contains("requesterLine"), "requesterLine is gone")
    }

    func testConnectIsDisabledWhenTheModelBlocksIt() throws {
        let lines = try confirmSheetCode().components(separatedBy: "\n")
        let mentions = lines.indices.filter { lines[$0].contains("connectBlockedReason") }
        XCTAssertFalse(mentions.isEmpty, "the sheet must read model.connectBlockedReason")
        let drivesEnabled = mentions.contains { i in
            lines[max(0, i - 3)...min(lines.count - 1, i + 3)].contains { $0.contains("connectButton.isEnabled") }
        }
        XCTAssertTrue(drivesEnabled, "connectBlockedReason must drive connectButton.isEnabled")
        let code = lines.joined(separator: "\n")
        let blocked = try XCTUnwrap(variable(withId: "remote-shell-blocked", in: code),
                                    "the reason Connect is off is shown in a label with id remote-shell-blocked")
        XCTAssertFalse(blocked.isEmpty)
    }

    func testConnectTappedRefusesWhenBlockedBeforeItCanSendConnect() throws {
        let url = Repo.app.appendingPathComponent("UI/Terminal/RemoteShellConfirmSheet.swift")
        let lines = Repo.codeLines(try Repo.read(url))
        let found = declarations(in: url.lastPathComponent, lines: lines) { lines[$0].contains("func connectTapped(") }
        let decl = try XCTUnwrap(found.first, "connectTapped not found")
        XCTAssertNotNil(Repo.firstMatch(#"(?s)connectBlockedReason.*?\breturn\b.*?decision:\s*\.connect"#, in: decl.body),
                        "connectTapped must check connectBlockedReason and return before it can answer .connect:\n\(decl.body)")
    }

    // MARK: Connecting overlay takes the keyboard away from the terminal

    private func paneHostDeclarations(_ name: String) throws -> Declaration {
        let host = try XCTUnwrap(try terminalViewSources().first { $0.name == "TerminalPaneHostView.swift" })
        let found = declarations(in: host.name, lines: host.lines) { host.lines[$0].contains("func \(name)(") }
        return try XCTUnwrap(found.first, "TerminalPaneHostView.\(name) not found")
    }

    func testShowingTheConnectingOverlayResignsTheTerminalsKeyboardFocus() throws {
        let decl = try paneHostDeclarations("renderConnecting")
        XCTAssertTrue(decl.body.contains("makeFirstResponder(nil)"), "connecting must give up first responder:\n\(decl.body)")
        XCTAssertTrue(decl.body.contains("firstResponder") && decl.body.contains("terminalView"),
                      "only when the terminal view is the first responder:\n\(decl.body)")
    }

    func testFocusTerminalDoesNotHandTheKeyboardToAConnectingTerminal() throws {
        let decl = try paneHostDeclarations("focusTerminal")
        let status = try XCTUnwrap(decl.body.range(of: ".connecting"), "focusTerminal must check for .connecting:\n\(decl.body)")
        XCTAssertTrue(decl.body.contains("info?.status") || decl.body.contains("info.status"), decl.body)
        let focus = try XCTUnwrap(decl.body.range(of: "makeFirstResponder(terminalView)"))
        XCTAssertLessThan(status.lowerBound, focus.lowerBound, "the connecting check comes before taking the keyboard")
    }

    func testTheRemoteShellSheetFilesExist() {
        for name in ["RemoteShellPresenter.swift", "NewRemoteShellSheet.swift", "RemoteShellFailureSheet.swift"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: Repo.app.appendingPathComponent("UI/Terminal/\(name)").path), "\(name) is missing")
        }
    }

    func testTheTerminalMenuHasNewRemoteShellOnShiftCommandT() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let terminal = try XCTUnwrap(topLevelMenu("Terminal", in: main), "no top-level Terminal menu").menu
        let entry = try XCTUnwrap(item("New Remote Shell\u{2026}", in: terminal))
        XCTAssertEqual(entry.keyEquivalent.lowercased(), "t")
        XCTAssertEqual(entry.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command, .shift])
        XCTAssertEqual(entry.action, #selector(MainMenuActions.newRemoteShell(_:)))
    }

    func testShiftCommandTIsClaimedByExactlyOneMenuItem() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        var owners: [String] = []
        for top in main.items {
            for entry in top.submenu?.items ?? [] where entry.keyEquivalent.lowercased() == "t" {
                let mask = entry.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                if mask == [.command, .shift] { owners.append(entry.title) }
            }
        }
        XCTAssertEqual(owners, ["New Remote Shell\u{2026}"], "claimed by \(owners)")
    }

    // MARK: 2d: Paste, Keep open, and the audit-log menu

    func testPasteAndKeepOpenAskTheControlGuard() throws {
        let sheet = try Repo.read(Repo.app.appendingPathComponent("UI/Terminal/PasteConfirmSheet.swift"))
        let pasteAction = try XCTUnwrap(sheet.range(of: "@objc private func pasteTapped"), "no pasteTapped")
        XCTAssertTrue(sheet[pasteAction.upperBound...].prefix(300).contains("TerminalInputGuard.allowsControl"),
                      "Paste must ask TerminalInputGuard.allowsControl before anything is sent")

        let host = try Repo.read(Repo.app.appendingPathComponent("UI/Terminal/TerminalPaneHostView.swift"))
        let keepOpen = try XCTUnwrap(host.range(of: "@objc private func keepOpenTapped"), "no keepOpenTapped")
        XCTAssertTrue(host[keepOpen.upperBound...].prefix(300).contains("TerminalInputGuard.allowsControl"),
                      "Keep open must ask TerminalInputGuard.allowsControl")
    }

    func testPasteConfirmCancelIsTheDefaultButtonAndPasteHasNoKeyEquivalent() throws {
        let sheet = try Repo.read(Repo.app.appendingPathComponent("UI/Terminal/PasteConfirmSheet.swift"))
        XCTAssertTrue(sheet.contains(#"cancelButton.keyEquivalent = "\r""#), "Cancel must be the default (Return) button")
        XCTAssertFalse(sheet.contains("pasteButton.keyEquivalent"), "Paste must have no key equivalent")
    }

    func testTheTerminalMenuHasTheAuditLogItemsWithoutShortcuts() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let terminal = try XCTUnwrap(topLevelMenu("Terminal", in: main), "no top-level Terminal menu").menu
        let show = try XCTUnwrap(item("Show Terminal Audit Log", in: terminal))
        XCTAssertEqual(show.action, #selector(MainMenuActions.showTerminalAuditLog(_:)))
        XCTAssertEqual(show.keyEquivalent, "")
        let reveal = try XCTUnwrap(item("Reveal Terminal Audit Log in Finder", in: terminal))
        XCTAssertEqual(reveal.action, #selector(MainMenuActions.revealTerminalAuditLog(_:)))
        XCTAssertEqual(reveal.keyEquivalent, "")
    }
}
