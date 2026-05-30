import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "chat")

/// Manages a persistent Claude Code session for one agent tag (fred / perri / teri).
///
/// Each `send(_:)` call spawns:
///   claude --dangerously-skip-permissions --output-format stream-json --no-color \
///          -p <text> [--resume <session_id>]
///
/// The session_id is persisted to ~/.nostromo/gui-sessions.json so sessions survive
/// GUI restarts (the Claude Code conversation history is stored server-side by session_id).
class ChatSession: ObservableObject {

    let tag: String            // session persistence key (unique per focus)
    let agentName: String      // passed to --agent flag (just the agent filename stem)
    let workingDirectory: String?

    @Published private(set) var turns:        [ChatTurn] = []
    @Published private(set) var isRunning:   Bool        = false
    @Published private(set) var pendingCount: Int        = 0

    private var sessionId:       String?
    private var currentProcess:  Process?
    private var lineBuffer:      String = ""
    private var pendingMessages: [String] = []

    init(tag: String, agentName: String? = nil, workingDirectory: String? = nil) {
        self.tag              = tag
        self.agentName        = agentName ?? tag  // built-ins: tag == agentName
        self.workingDirectory = workingDirectory
        self.sessionId        = Self.loadId(tag)
        log.info("ChatSession[\(tag, privacy: .public)] init sid=\(self.sessionId ?? "none", privacy: .public)")
        // Pre-populate turns from the persisted session JSONL so the scrollback
        // is visible immediately on app launch / tab switch.
        if let sid = sessionId {
            turns = Self.loadScrollback(sessionId: sid)
        }
    }

    /// Clear local display and start a fresh Claude session (new session_id on next send).
    func newSession() {
        turns          = []
        sessionId      = nil
        pendingMessages = []
        pendingCount   = 0
        Self.saveId(nil, tag)
        log.info("ChatSession[\(self.tag, privacy: .public)] cleared — next send starts fresh session")
    }

    // MARK: - Send

    func send(_ text: String, images: [URL] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Queue if a turn is already in-flight — drain after finishTurn.
        // (Images can only be sent immediately, not queued; they're discarded if queued.)
        if isRunning {
            pendingMessages.append(trimmed)
            pendingCount = pendingMessages.count
            return
        }

        let turn = ChatTurn(userInput: trimmed, timestamp: Date())
        turns.append(turn)
        let turnId = turn.id
        isRunning  = true
        lineBuffer = ""

        guard let claude = Self.findClaude() else {
            fail(turnId: turnId,
                 message: "Cannot find `claude` binary.\nInstall Claude Code CLI and make sure it's on PATH.")
            return
        }

        var args: [String] = [
            "--dangerously-skip-permissions",
            "--output-format", "stream-json",
            "--verbose",
            "--agent", agentName,
            "-p", trimmed,
        ]
        if let sid = sessionId { args += ["--resume", sid] }
        // NOTE: `--image` is not a valid claude CLI flag. Image forwarding via
        // `--file` (the CLI's actual flag) needs investigation; for now images
        // are surfaced in the UI but not forwarded to the subprocess.

        let proc = Process()
        proc.executableURL = claude
        proc.arguments     = args
        if let dir = workingDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: dir)
        }

        // Augment PATH so claude can find its own helpers
        var env  = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "\(home)/.npm/bin",
            "\(home)/.nvm/versions/node/current/bin",
        ].joined(separator: ":")
        env["PATH"] = (env["PATH"] ?? "") + ":" + extra
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty, let self else { return }
            if let chunk = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { self.processChunk(chunk, turnId: turnId) }
            }
        }

        // Drain stderr asynchronously to prevent the kernel pipe buffer from filling
        // and blocking the child process before it exits (which would deadlock
        // terminationHandler). readabilityHandler fires on a background thread and
        // accumulates data safely; terminationHandler just reads the accumulated buffer.
        var errBuffer = Data()
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if data.isEmpty {
                fh.readabilityHandler = nil   // EOF
            } else {
                errBuffer.append(data)
            }
        }

        proc.terminationHandler = { [weak self] p in
            guard let self else { return }
            errPipe.fileHandleForReading.readabilityHandler = nil
            let errStr = String(data: errBuffer, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                // Flush any partial final line
                if !self.lineBuffer.isEmpty {
                    self.processLine(self.lineBuffer, turnId: turnId)
                    self.lineBuffer = ""
                }
                if p.terminationStatus != 0, !errStr.isEmpty {
                    let msg = errStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.appendBlock(.errorMessage(msg), to: turnId)
                }
                self.finishTurn(turnId)
            }
        }

        currentProcess = proc
        do    { try proc.run() }
        catch { fail(turnId: turnId, message: "Failed to launch claude: \(error.localizedDescription)") }
    }

    // MARK: - Stream processing

    private func processChunk(_ chunk: String, turnId: UUID) {
        lineBuffer += chunk
        var lines  = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.removeLast()  // keep incomplete trailing fragment
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            processLine(line, turnId: turnId)
        }
    }

    private func processLine(_ line: String, turnId: UUID) {
        guard let result = TurnBlock.parse(line: line) else { return }
        switch result {
        case .sessionId(let sid):
            log.info("ChatSession[\(self.tag, privacy: .public)] session_id=\(sid, privacy: .public)")
            sessionId = sid
            Self.saveId(sid, tag)
        case .blocks(let blocks):
            blocks.forEach { appendBlock($0, to: turnId) }
        }
    }

    // MARK: - Helpers

    private func appendBlock(_ block: TurnBlock, to turnId: UUID) {
        guard let idx = turns.firstIndex(where: { $0.id == turnId }) else { return }
        turns[idx].blocks.append(block)
    }

    private func finishTurn(_ id: UUID) {
        if let idx = turns.firstIndex(where: { $0.id == id }) {
            turns[idx].isComplete = true
        }
        isRunning      = false
        currentProcess = nil

        // Drain one queued message if any.
        if !pendingMessages.isEmpty {
            let next = pendingMessages.removeFirst()
            pendingCount = pendingMessages.count
            send(next)
        }
    }

    private func fail(turnId: UUID, message: String) {
        appendBlock(.errorMessage(message), to: turnId)
        finishTurn(turnId)
    }

    // MARK: - Session ID persistence

    private static var storageURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nostromo")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gui-sessions.json")
    }()

    private static func loadId(_ tag: String) -> String? {
        guard
            let data = try? Data(contentsOf: storageURL),
            let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return dict[tag]
    }

    private static func saveId(_ sid: String?, _ tag: String) {
        var dict: [String: String] = (try? Data(contentsOf: storageURL))
            .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        if let sid {
            dict[tag] = sid
        } else {
            dict.removeValue(forKey: tag)
        }
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    // MARK: - Scrollback

    /// Replays the last `maxTurns` turns from the persisted session JSONL.
    ///
    /// Sessions are stored under ~/.claude/projects/<encoded-path>/<sessionId>.jsonl
    /// where the encoded path depends on the working directory the session was started in.
    /// Sessions without a project use the literal subdirectory "-".
    /// We search all subdirectories so dynamic focuses (which have a workingDirectory)
    /// are found even when the encoded path isn't known at load time.
    private static func loadScrollback(sessionId: String, maxTurns: Int = 30) -> [ChatTurn] {
        let home        = FileManager.default.homeDirectoryForCurrentUser
        let projectsDir = home.appendingPathComponent(".claude/projects")

        // Search every immediate subdirectory for <sessionId>.jsonl
        let subdirs = (try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles)) ?? []
        let fm = FileManager.default
        var path: URL? = nil
        for sub in subdirs {
            guard (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let candidate = sub.appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) { path = candidate; break }
        }
        guard let path else { return [] }

        guard
            let data    = try? Data(contentsOf: path),
            let content = String(data: data, encoding: .utf8)
        else { return [] }

        let isoFormatter = ISO8601DateFormatter()
        var turns:       [ChatTurn] = []
        var pendingTurn: ChatTurn?  = nil

        func flushPending() {
            guard let t = pendingTurn, !t.blocks.isEmpty else { return }
            var completed = t; completed.isComplete = true
            turns.append(completed)
            pendingTurn = nil
        }

        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json     = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            switch json["type"] as? String ?? "" {

            case "user":
                let msg        = json["message"] as? [String: Any]
                let rawContent = msg?["content"]
                let ts = (json["timestamp"] as? String)
                    .flatMap { isoFormatter.date(from: $0) } ?? Date()

                if let text = rawContent as? String, !text.isEmpty {
                    // Plain string → new human turn
                    flushPending()
                    pendingTurn = ChatTurn(userInput: text, timestamp: ts)
                } else if let arr = rawContent as? [[String: Any]] {
                    let allToolResults = arr.allSatisfy { $0["type"] as? String == "tool_result" }
                    if allToolResults {
                        // Tool result → belongs to current turn
                        if case .blocks(let blocks) = TurnBlock.parse(line: line) {
                            blocks.forEach { pendingTurn?.blocks.append($0) }
                        }
                    } else {
                        // Text-array user message → new human turn
                        let text = arr.compactMap {
                            $0["type"] as? String == "text" ? $0["text"] as? String : nil
                        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            flushPending()
                            pendingTurn = ChatTurn(userInput: text, timestamp: ts)
                        }
                    }
                }

            case "assistant":
                if let result = TurnBlock.parse(line: line), case .blocks(let blocks) = result {
                    blocks.forEach { pendingTurn?.blocks.append($0) }
                }

            default:
                break
            }
        }
        flushPending()

        return Array(turns.suffix(maxTurns))
    }

    // MARK: - Binary discovery

    /// Searches common install locations for the `claude` CLI binary.
    static func findClaude() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
            "\(home)/.npm/bin/claude",
            "\(home)/.nvm/versions/node/current/bin/claude",
            "\(home)/.nvm/versions/node/lts/bin/claude",
            "\(home)/.local/bin/claude",
        ]
        if let hit = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            return URL(fileURLWithPath: hit)
        }
        // Last resort: ask `which`
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments     = ["claude"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        try? proc.run()
        proc.waitUntilExit()
        let p = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return p.isEmpty ? nil : URL(fileURLWithPath: p)
    }
}
