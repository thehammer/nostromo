import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo", category: "terminal")

/// A view that shows one terminal's bytes (`TerminalPaneHostView`; tests pass fakes).
/// Main thread only. Nothing here imports SwiftTerm.
protocol TerminalByteSink: AnyObject {
    /// The window this view lives in: the key of a pending keyboard-focus token.
    var windowId: String { get }
    /// The size the view wants its terminal to have, once it has been laid out. The store sends it
    /// before it attaches, so the daemon's replay already has this size.
    var preferredSize: (cols: Int, rows: Int)? { get }
    /// Bytes to draw.
    func feed(_ bytes: [UInt8])
    /// Forget the screen: a replay is about to be fed.
    func reset()
    /// The daemon's size for this terminal (from a replay).
    func apply(cols: Int, rows: Int)
    /// Make the terminal the window's first responder (a terminal this window just opened).
    func takeKeyboardFocus()
}

/// Marks a view as a terminal pane, so code that also builds in the test bundle (`DynamicFocusView`)
/// can recognise one without naming the SwiftTerm-linked class.
protocol TerminalPaneLeaf: AnyObject {}

/// What `TerminalSessionStore.changes` announces.
enum TerminalChange: Equatable {
    case info(TerminalInfo)
    case closed(TerminalClosedInfo)
    case refused(TerminalRefusedFrame)
}

/// Every terminal the daemon told this app about, and the views showing them.
///
/// - One `TerminalInfo` per `terminal_id` (the latest), and a `TerminalByteSink` registry per pane.
/// - A bounded local copy of each attached terminal's bytes, so a second window's view starts with
///   the screen the first one has instead of waiting for the daemon.
/// - Attach and detach are reference counted: `terminal_attach` goes out for the first sink of a
///   terminal, `terminal_detach` after its last. On a reconnect every terminal that still has a
///   sink is attached again.
/// - Input, resize, close and restart go out through `transport`; none of them is sent for a
///   terminal the daemon has not described.
///
/// Main thread only (it is fed from `AppStore.handle` and called from views).
final class TerminalSessionStore {
    static let shared = TerminalSessionStore()

    /// The most bytes kept per terminal to start a late view. The oldest are dropped first, and the
    /// copy then starts at a line boundary.
    static let replayCapacity = 2 * 1024 * 1024
    /// The most bytes one `terminal_input` frame carries. The daemon refuses a frame over 256 KiB
    /// (`terminal_input_too_large`) and queues at most 1 MiB for a program that is not reading, so a
    /// larger paste goes out in frames this size, in order, spaced by `inputChunkInterval`.
    static let inputChunkBytes = 32 * 1024
    /// The gap between two chunks of one large paste.
    static let inputChunkInterval: TimeInterval = 0.01
    /// How long a keyboard-focus claim for a terminal this window opened waits for its view.
    static let focusClaimLifetime: TimeInterval = 10
    /// The shortest gap between two refusal reports of one kind for one terminal.
    static let refusalReportInterval: TimeInterval = 1

    /// Announces every `terminal_state`, `terminal_closed` and `terminal_refused`.
    let changes = PassthroughSubject<TerminalChange, Never>()

    /// Sends one frame to the daemon (`AppStore` points it at the client; dropped when not connected).
    var transport: (TerminalClientMessage) -> Void

    private(set) var terminals: [String: TerminalInfo] = [:]
    /// The last window that sent input to each terminal (the driver rule in a later slice reads it).
    private(set) var lastInputWindow: [String: String] = [:]

    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    /// Bytes copied out of a terminal's replay buffer (a late view starting, or a replay trim). Reading
    /// a frame in does not copy the buffer: tests watch this stay flat while output streams.
    private(set) var replayBytesMaterialized = 0

    private final class Binding {
        weak var sink: TerminalByteSink?
        let tag: String
        let paneId: String
        var terminalId: String?
        init(sink: TerminalByteSink, tag: String, paneId: String) {
            self.sink = sink
            self.tag = tag
            self.paneId = paneId
        }
    }

    private var bindings: [Binding] = []
    private var replayCopy: [String: ReplayBuffer] = [:]
    /// Input frames waiting their turn behind a large paste, per terminal (oldest first).
    private var inputBacklog: [String: [TerminalClientMessage]] = [:]
    private var attached: Set<String> = []
    private var knownSize: [String: [Int]] = [:]
    private var connected = false

    /// `client_request_id` -> window id, for terminals this app asked to open.
    private var pendingFocus: [String: String] = [:]
    /// terminal id -> (window id, when the claim was made), once the daemon said the terminal exists.
    private var focusClaims: [String: (windowId: String, at: Date)] = [:]
    private var lastRefusalReport: [String: Date] = [:]

    init(now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
         },
         transport: @escaping (TerminalClientMessage) -> Void = { _ in }) {
        self.now = now
        self.schedule = schedule
        self.transport = transport
    }

    // MARK: - Queries

    /// The terminal the daemon says occupies `paneId` of `tag`'s tree, if it has said so yet.
    func info(forPane paneId: String, tag: String) -> TerminalInfo? {
        terminals.values.first { $0.paneId == paneId && $0.tag == tag }
    }

    /// How many live views show `terminalId`.
    func sinkCount(for terminalId: String) -> Int {
        liveBindings(for: terminalId).count
    }

    // MARK: - Views

    /// A view for `paneId` of `tag`'s tree starts showing the terminal that occupies it (now, or when
    /// the daemon describes it). Registering the same view for the same pane again changes nothing; for another pane it replaces the earlier registration.
    func register(_ sink: TerminalByteSink, tag: String, paneId: String) {
        if bindings.contains(where: { $0.sink === sink && $0.tag == tag && $0.paneId == paneId }) { return }
        unregister(sink)
        let binding = Binding(sink: sink, tag: tag, paneId: paneId)
        bindings.append(binding)
        if let info = info(forPane: paneId, tag: tag) {
            bind(binding, to: info)
        }
    }

    /// The view is gone (or hidden): it no longer receives bytes. The last view of a terminal detaches it.
    func unregister(_ sink: TerminalByteSink) {
        let leaving = bindings.filter { $0.sink == nil || $0.sink === sink }
        bindings.removeAll { $0.sink == nil || $0.sink === sink }
        for binding in leaving {
            if let id = binding.terminalId { releaseIfUnused(id) }
        }
    }

    // MARK: - Daemon frames

    func ingest(_ msg: ServerMsg) {
        switch msg {
        case .terminalList(let frame):
            for info in frame.terminals { apply(info) }
            for closed in frame.closed { apply(closed: closed) }
        case .terminalState(let info):
            apply(info)
        case .terminalClosed(let closed):
            apply(closed: closed)
        case .terminalReplay(let frame):
            apply(replay: frame)
        case .terminalOutput(let frame):
            apply(output: frame)
        case .terminalRefused(let frame):
            log.info("terminal refused: op=\(frame.op, privacy: .public) code=\(frame.code, privacy: .public)")
            changes.send(.refused(frame))
        default:
            break
        }
    }

    /// The daemon connection came up or went down. A dropped connection ends every attachment; a new
    /// one attaches again every terminal that still has a view.
    func connectionChanged(_ isConnected: Bool) {
        connected = isConnected
        if !isConnected {
            attached.removeAll()
            return
        }
        for id in Set(bindings.compactMap { $0.sink == nil ? nil : $0.terminalId }) where !attached.contains(id) {
            attach(id)
        }
    }

    // MARK: - Commands from views

    /// Keystrokes, a paste or a terminal's own reply (`autoReply`). Dropped unless the terminal is running.
    ///
    /// A reply is not a person at the keyboard: it is marked on the wire so the daemon does not treat it
    /// as activity, and it does not make this window the terminal's driver.
    ///
    /// Bytes over `inputChunkBytes` go out in several frames, in order, a few milliseconds apart. While
    /// they are going out, anything else for that terminal (a key, a reply) queues behind them, so a
    /// paste is never split by what the person types next.
    func sendInput(terminalId: String, bytes: [UInt8], fromWindow windowId: String, autoReply: Bool = false) {
        guard !bytes.isEmpty, terminals[terminalId]?.status == .running else { return }
        if !autoReply { lastInputWindow[terminalId] = windowId }
        var frames: [TerminalClientMessage] = []
        var start = 0
        while start < bytes.count {
            let end = min(start + Self.inputChunkBytes, bytes.count)
            let chunk = (start == 0 && end == bytes.count) ? bytes : Array(bytes[start..<end])
            frames.append(.input(terminalId: terminalId, bytes: chunk, autoReply: autoReply))
            start = end
        }
        if inputBacklog[terminalId] == nil && frames.count == 1 {
            transport(frames[0])
            return
        }
        let draining = inputBacklog[terminalId] != nil
        inputBacklog[terminalId, default: []].append(contentsOf: frames)
        if !draining { drainInput(terminalId) }
    }

    /// The view's grid changed size. Not sent when the daemon already has that size.
    func resize(terminalId: String, cols: Int, rows: Int, fromWindow windowId: String) {
        guard cols > 0, rows > 0, terminals[terminalId] != nil else { return }
        guard knownSize[terminalId] != [cols, rows] else { return }
        knownSize[terminalId] = [cols, rows]
        transport(.resize(terminalId: terminalId, cols: cols, rows: rows))
    }

    func close(terminalId: String) {
        transport(.close(terminalId: terminalId))
    }

    func restart(terminalId: String) {
        transport(.restart(terminalId: terminalId))
    }

    /// Tell the daemon an input that was not a person's was refused here (audited as `app_control`).
    /// At most one report per second for each kind of refusal on each terminal.
    func reportRefusal(terminalId: String?, op: TerminalRefusedOp) {
        let key = "\(terminalId ?? "-")/\(op.rawValue)"
        let at = now()
        if let last = lastRefusalReport[key], at.timeIntervalSince(last) < Self.refusalReportInterval { return }
        lastRefusalReport[key] = at
        transport(.refusalReport(terminalId: terminalId, op: op, channel: "app_control"))
    }

    // MARK: - Opening a terminal from this app

    /// This app is about to ask for a terminal with `clientRequestId` from the window `windowId`:
    /// when the daemon reports it, that window's view takes the keyboard. A terminal an agent opened
    /// has no token and never does.
    func expectKeyboardFocus(clientRequestId: String, windowId: String) {
        if pendingFocus.count >= 16 { pendingFocus.removeAll() }
        pendingFocus[clientRequestId] = windowId
    }

    // MARK: - Private

    /// Send the next waiting frame of `id` and, if more wait, come back for them after a short gap.
    private func drainInput(_ id: String) {
        guard terminals[id]?.status == .running, var queue = inputBacklog[id], !queue.isEmpty else {
            inputBacklog.removeValue(forKey: id)
            return
        }
        transport(queue.removeFirst())
        if queue.isEmpty {
            inputBacklog.removeValue(forKey: id)
            return
        }
        inputBacklog[id] = queue
        schedule(Self.inputChunkInterval) { [weak self] in self?.drainInput(id) }
    }

    private func liveBindings(for terminalId: String) -> [Binding] {
        bindings.filter { $0.terminalId == terminalId && $0.sink != nil }
    }

    private func apply(_ info: TerminalInfo) {
        let id = info.terminalId
        terminals[id] = info
        knownSize[id] = [info.cols, info.rows]
        // A restart replaces the terminal in the same pane under a new id; the old record is gone.
        for (oldId, old) in terminals where oldId != id && old.paneId == info.paneId && old.tag == info.tag {
            forget(oldId)
        }
        if let request = info.openedByRequest, let window = pendingFocus.removeValue(forKey: request) {
            focusClaims[id] = (window, now())
        }
        for binding in bindings where binding.tag == info.tag && binding.paneId == info.paneId && binding.sink != nil {
            bind(binding, to: info)
        }
        deliverFocusClaim(for: id)
        changes.send(.info(info))
    }

    private func apply(closed: TerminalClosedInfo) {
        forget(closed.terminalId)
        changes.send(.closed(closed))
    }

    private func apply(replay frame: TerminalReplayFrame) {
        let id = frame.terminalId
        knownSize[id] = [frame.cols, frame.rows]
        var copy = ReplayBuffer(capacity: Self.replayCapacity)
        copy.append(frame.bytes)
        replayCopy[id] = copy
        for binding in liveBindings(for: id) {
            binding.sink?.reset()
            binding.sink?.apply(cols: frame.cols, rows: frame.rows)
            binding.sink?.feed(frame.bytes)
        }
    }

    private func apply(output frame: TerminalOutputFrame) {
        let id = frame.terminalId
        guard attached.contains(id) || !liveBindings(for: id).isEmpty else { return }
        replayCopy[id, default: ReplayBuffer(capacity: Self.replayCapacity)].append(frame.bytes)
        for binding in liveBindings(for: id) {
            binding.sink?.feed(frame.bytes)
        }
    }

    /// Start showing `info` in `binding`'s view.
    private func bind(_ binding: Binding, to info: TerminalInfo) {
        let id = info.terminalId
        guard binding.terminalId != id, let sink = binding.sink else { return }
        if let previous = binding.terminalId {
            binding.terminalId = nil
            releaseIfUnused(previous)
        }
        let othersShowingIt = liveBindings(for: id)
        binding.terminalId = id
        if othersShowingIt.isEmpty {
            // First view: say how big it is, then attach, so the replay is already that size.
            if let size = sink.preferredSize, knownSize[id] != [size.cols, size.rows] {
                knownSize[id] = [size.cols, size.rows]
                transport(.resize(terminalId: id, cols: size.cols, rows: size.rows))
            }
            attach(id)
        } else {
            // A later view starts from the copy the first one has.
            sink.reset()
            if let size = knownSize[id] { sink.apply(cols: size[0], rows: size[1]) }
            if let copy = replayCopy[id] {
                let bytes = copy.contents()
                replayBytesMaterialized += bytes.count
                if !bytes.isEmpty { sink.feed(bytes) }
            }
        }
        deliverFocusClaim(for: id)
    }

    private func attach(_ id: String) {
        guard connected, !attached.contains(id) else { return }
        attached.insert(id)
        transport(.attach(terminalId: id))
    }

    /// The last view of `id` is gone: stop the daemon streaming it, and drop the copy.
    private func releaseIfUnused(_ id: String) {
        guard liveBindings(for: id).isEmpty else { return }
        replayCopy.removeValue(forKey: id)
        if attached.remove(id) != nil, connected, terminals[id] != nil {
            transport(.detach(terminalId: id))
        }
    }

    private func forget(_ id: String) {
        terminals.removeValue(forKey: id)
        replayCopy.removeValue(forKey: id)
        inputBacklog.removeValue(forKey: id)
        knownSize.removeValue(forKey: id)
        attached.remove(id)
        focusClaims.removeValue(forKey: id)
        lastInputWindow.removeValue(forKey: id)
        for binding in bindings where binding.terminalId == id { binding.terminalId = nil }
    }

    private func deliverFocusClaim(for id: String) {
        guard let claim = focusClaims[id] else { return }
        if now().timeIntervalSince(claim.at) > Self.focusClaimLifetime {
            focusClaims.removeValue(forKey: id)
            return
        }
        guard let target = liveBindings(for: id).first(where: { $0.sink?.windowId == claim.windowId }) else { return }
        focusClaims.removeValue(forKey: id)
        target.sink?.takeKeyboardFocus()
    }

    /// Keep the newest `replayCapacity` bytes, starting at a line boundary when one is near.
    static func trimmed(_ bytes: [UInt8], capacity: Int = replayCapacity) -> [UInt8] {
        guard bytes.count > capacity else { return bytes }
        var out = Array(bytes.suffix(capacity))
        if let newline = out.prefix(4096).firstIndex(of: 0x0A) { out.removeFirst(newline + 1) }
        return out
    }
}

/// The newest bytes of one terminal's output, kept as the frames they arrived in. Taking a frame in
/// is O(1) (the frame's storage is shared, nothing is copied) and whole old frames are dropped from
/// the front; the bytes are joined and trimmed to `capacity` only when a late view asks for them.
struct ReplayBuffer {
    let capacity: Int
    private var chunks: [[UInt8]] = []
    /// `chunks[..<head]` are dropped.
    private var head = 0
    private var held = 0

    init(capacity: Int) { self.capacity = capacity }

    mutating func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        chunks.append(bytes)
        held += bytes.count
        // Drop the oldest whole frames while what is left still covers `capacity`.
        while head < chunks.count - 1, held - chunks[head].count >= capacity {
            held -= chunks[head].count
            chunks[head] = []
            head += 1
        }
        if head >= 64, head * 2 >= chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
    }

    /// The newest `capacity` bytes, in order, starting at a line boundary when one is near.
    func contents() -> [UInt8] {
        var joined: [UInt8] = []
        joined.reserveCapacity(held)
        for chunk in chunks[head...] { joined.append(contentsOf: chunk) }
        return TerminalSessionStore.trimmed(joined, capacity: capacity)
    }
}

// MARK: - Refused input

extension TerminalRefusedFrame {
    /// The one message the pane's overlay shows when the daemon refused input it was sent (a paste it
    /// could not take). Fixed text: nothing of what was typed or pasted is ever in it.
    static let inputNotice = "[input not delivered: the terminal refused it (too large, or the program is not reading)]"

    /// `inputNotice` for a refused `terminal_input`, else nil.
    var overlayNotice: String? {
        guard op == "input", code == "terminal_input_too_large" || code == "terminal_input_busy" else { return nil }
        return Self.inputNotice
    }
}

// MARK: - Header text

extension TerminalInfo {
    /// The pane's header text: a remote shell's own label, else `zsh: ~/Code/nostromo` (the shell and
    /// the directory it started in), else the daemon's label.
    func headerTitle(home: String = NSHomeDirectory(), shell: String? = ProcessInfo.processInfo.environment["SHELL"]) -> String {
        guard kind == .local, let cwd, !cwd.isEmpty else { return label }
        let shortCwd: String
        if cwd == home { shortCwd = "~" }
        else if cwd.hasPrefix(home + "/") { shortCwd = "~" + cwd.dropFirst(home.count) }
        else { shortCwd = cwd }
        let name = shell.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? label
        return "\(name): \(shortCwd)"
    }
}
