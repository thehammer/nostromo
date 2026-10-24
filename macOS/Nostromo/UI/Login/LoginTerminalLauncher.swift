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
    /// Run `executable` with `arguments` to completion; its exit status, or nil if it did not start
    /// or did not finish in a bounded time.
    func run(_ executable: String, arguments: [String]) -> Int32?
    /// Like `run`, but the text it printed on success; nil if it did not start, did not finish in a
    /// bounded time, or exited non-zero.
    func output(of executable: String, arguments: [String]) -> String?
    /// Open `file` with the Terminal app. True if the open was requested.
    func openInTerminal(_ file: URL) -> Bool
}

struct SystemProcessLauncher: ProcessLaunching {
    func isExecutable(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// How long a helper (tmux) may take before it is stopped and counts as failed.
    static let timeout: TimeInterval = 3

    func run(_ executable: String, arguments: [String]) -> Int32? {
        execute(executable, arguments: arguments, capture: false)?.status
    }

    func output(of executable: String, arguments: [String]) -> String? {
        guard let result = execute(executable, arguments: arguments, capture: true), result.status == 0 else { return nil }
        return result.output
    }

    /// Never waits on the calling thread past `timeout`: a wedged tmux is killed, not waited for.
    private func execute(_ executable: String, arguments: [String], capture: Bool) -> (status: Int32, output: String)? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        proc.standardOutput = capture ? pipe : FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do { try proc.run() } catch { return nil }
        var data = Data()
        if capture {
            // Drain off this thread so a chatty child cannot fill the pipe and stall.
            let reader = DispatchQueue.global(qos: .userInitiated)
            let read = DispatchSemaphore(value: 0)
            reader.async {
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                read.signal()
            }
            guard done.wait(timeout: .now() + Self.timeout) == .success,
                  read.wait(timeout: .now() + Self.timeout) == .success else {
                proc.terminate()
                return nil
            }
        } else if done.wait(timeout: .now() + Self.timeout) != .success {
            proc.terminate()
            return nil
        }
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func openInTerminal(_ file: URL) -> Bool {
        // AppKit's workspace is main-thread territory; the launcher calls this from a background queue.
        let request = {
            guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return false }
            NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return Thread.isMainThread ? request() : DispatchQueue.main.sync(execute: request)
    }
}

struct LoginTerminalLauncher {

    static let tmuxPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    static let windowName = "claude-sign-in"
    static let scriptDirectoryName = "nostromo-sign-in"
    static let scriptName = "claude-sign-in.command"

    let process: ProcessLaunching
    let temporaryDirectory: String
    /// Where the blocking work runs, and where the answer is delivered. A test runs both inline.
    private let background: (@escaping () -> Void) -> Void
    private let deliver: (@escaping () -> Void) -> Void

    init(process: ProcessLaunching = SystemProcessLauncher(), temporaryDirectory: String = NSTemporaryDirectory(),
         background: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
         deliver: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.process = process
        self.temporaryDirectory = temporaryDirectory
        self.background = background
        self.deliver = deliver
    }

    /// Where the `.command` file is written.
    var scriptURL: URL {
        URL(fileURLWithPath: temporaryDirectory, isDirectory: true)
            .appendingPathComponent(Self.scriptDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.scriptName)
    }

    /// Start the sign-in off the main thread; `completion` runs on the main thread with where it
    /// opened, or nil when nothing could be opened (the card then says so).
    func open(claudeBin: String, completion: @escaping (LoginTerminalOutcome?) -> Void) {
        background {
            let outcome = openNow(claudeBin: claudeBin)
            deliver { completion(outcome) }
        }
    }

    /// The blocking part of `open`. Never call it from the main thread outside a test.
    func openNow(claudeBin: String) -> LoginTerminalOutcome? {
        guard isUsable(claudeBin) else { return nil }
        if let session = attachedTmuxSession(), let tmux = tmuxPath {
            // `-t` names the session a person is looking at, so the window opens where they can see it.
            let argv = ["new-window", "-t", session + ":", "-n", Self.windowName, "--", claudeBin, "auth", "login"]
            if process.run(tmux, arguments: argv) == 0 { return .tmuxWindow }
        }
        guard writeScript(claudeBin: claudeBin), process.openInTerminal(scriptURL) else { return nil }
        return .terminalApp
    }

    /// An absolute path to something that can run: no newline or NUL, and executable.
    private func isUsable(_ claudeBin: String) -> Bool {
        claudeBin.hasPrefix("/") && !claudeBin.contains("\n") && !claudeBin.contains("\0")
            && process.isExecutable(atPath: claudeBin)
    }

    private var tmuxPath: String? {
        Self.tmuxPaths.first(where: { process.isExecutable(atPath: $0) })
    }

    /// The session of a tmux client that is attached right now. A tmux server with no attached
    /// client would open the window where nobody is looking, so that is not a tmux to use.
    private func attachedTmuxSession() -> String? {
        guard let tmux = tmuxPath,
              let listing = process.output(of: tmux, arguments: ["list-clients", "-F", "#{client_session}"]) else { return nil }
        return listing.split(separator: "\n").map(String.init).first { !$0.isEmpty }
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
