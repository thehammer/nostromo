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
        XCTAssertTrue(after[..<branchEnd].contains("TerminalPaneHostView"),
                      "a terminal- pane must be built as a TerminalPaneHostView")
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
                     "UI/Terminal/PastePolicy.swift", "UI/Terminal/FollowModel.swift", "Data/TurnOrigin.swift"],
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
                     "TerminalStoreMirrorTests.swift", "FollowModelTests.swift", "TurnOriginTests.swift"],
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

    func testEditHasFindAndFindNextThatActOnTheFirstResponder() throws {
        _ = NSApplication.shared
        let main = MainMenu.make(target: nil)
        let edit = try XCTUnwrap(topLevelMenu("Edit", in: main)).menu

        let find = try XCTUnwrap(item("Find\u{2026}", in: edit), "Edit has no Find\u{2026}")
        XCTAssertEqual(find.keyEquivalent, "f")
        XCTAssertEqual(find.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command])
        XCTAssertEqual(find.action, Selector(("performFindPanelAction:")))
        XCTAssertEqual(find.tag, NSTextFinder.Action.showFindInterface.rawValue)
        XCTAssertNil(find.target, "no target: the action goes to the first responder")

        let next = try XCTUnwrap(item("Find Next", in: edit), "Edit has no Find Next")
        XCTAssertEqual(next.keyEquivalent, "g")
        XCTAssertEqual(next.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command])
        XCTAssertEqual(next.action, Selector(("performFindPanelAction:")))
        XCTAssertEqual(next.tag, NSTextFinder.Action.nextMatch.rawValue)
        XCTAssertNil(next.target)
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
}
