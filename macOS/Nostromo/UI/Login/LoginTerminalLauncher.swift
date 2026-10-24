import AppKit

// CL2 (D8): opens a terminal for the person to run `claude auth login` in.
//
// Called only after `HumanGesture.permit` said `.human`. Nothing is ever typed into the
// terminal, nothing is automated, and no credential is read: it starts `claude auth login` and
// the person completes the browser sign-in themselves.

/// How the terminal was opened (the card says which).
enum LoginTerminalOutcome: Equatable {
    case tmuxWindow
    case terminalApp
}

/// The side effects the launcher needs, so a test can record them.
protocol ProcessLaunching {
    func isExecutable(atPath path: String) -> Bool
    /// Run `executable` with `arguments` to completion; its exit status, or nil if it did not start.
    func run(_ executable: String, arguments: [String]) -> Int32?
    /// Open `file` with the Terminal app. True if the open was requested.
    func openInTerminal(_ file: URL) -> Bool
}

struct SystemProcessLauncher: ProcessLaunching {
    func isExecutable(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func run(_ executable: String, arguments: [String]) -> Int32? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        return proc.terminationStatus
    }

    func openInTerminal(_ file: URL) -> Bool {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return false }
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}

struct LoginTerminalLauncher {

    static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    static let windowName = "claude-sign-in"
    static let scriptDirectoryName = "nostromo-sign-in"
    static let scriptName = "claude-sign-in.command"

    let process: ProcessLaunching
    let temporaryDirectory: String

    init(process: ProcessLaunching = SystemProcessLauncher(), temporaryDirectory: String = NSTemporaryDirectory()) {
        self.process = process
        self.temporaryDirectory = temporaryDirectory
    }

    /// Where the `.command` file is written.
    var scriptURL: URL {
        URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
            .appendingPathComponent(Self.scriptDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.scriptName)
    }

    /// Start the sign-in. Nil when nothing could be opened (the card then says so).
    func open(claudeBin: String) -> LoginTerminalOutcome? {
        guard !claudeBin.isEmpty, !claudeBin.contains("\n"), !claudeBin.contains("\0") else { return nil }
        if let tmux = Self.tmuxPaths.first(where: { process.isExecutable(atPath: $0) }),
           process.run(tmux, arguments: ["has-session"]) == 0 {
            let argv = ["new-window", "-n", Self.windowName, "--", claudeBin, "auth", "login"]
            if process.run(tmux, arguments: argv) == 0 { return .tmuxWindow }
        }
        guard writeScript(claudeBin: claudeBin), process.openInTerminal(scriptURL) else { return nil }
        return .terminalApp
    }

    /// The text of the `.command` file.
    static func scriptContents(claudeBin: String) -> String {
        "#!/bin/sh\nexec \(shellQuoted(claudeBin)) auth login\n"
    }

    /// Single-quoted for `sh`: each `'` becomes `'\''`.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func writeScript(claudeBin: String) -> Bool {
        let fm = FileManager.default
        let url = scriptURL
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? fm.removeItem(at: url)
            let made = fm.createFile(atPath: url.path, contents: Data(Self.scriptContents(claudeBin: claudeBin).utf8),
                                     attributes: [.posixPermissions: 0o700])
            guard made else { return false }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
