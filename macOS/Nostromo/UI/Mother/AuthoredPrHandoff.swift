import AppKit
import Combine
import NostromoKit
import os

// The hand-off from the PR Overview: one explicit, human click opens a preview of a message the daemon built
// from structured facts, Send puts it in the owner focus's conversation, and Nostromo then shows that focus
// with the keyboard in its input.
//
// Nothing here composes or edits the message. The app asks the daemon for it, shows it verbatim and echoes
// the daemon's digest back. Every action entry point (the row's button, Return, a picker choice, Send,
// Start and send, Unlink) first asks `HumanGesture`: input synthesised by the app-control socket, an
// Accessibility press or a stale event does nothing, and is logged by code only.

private let handoffLog = Logger(subsystem: "com.hammer.nostromo", category: "authored-prs")

// MARK: - Human gesture

enum AuthoredPrGesture {
    /// `(event, control, action)`: may a person's gesture act here? `action` is a fixed word for the log.
    typealias Permit = (NSEvent?, NSView, String) -> Bool

    static let live: Permit = { event, control, action in
        if isRepeat(event) { return refuseRepeat(action) }
        return verdict(HumanGesture.permit(event, control: control), action)
    }

    /// A context-menu item: AppKit hands it the mouse event that tracked the menu.
    static let liveMenu: Permit = { event, control, action in
        if isRepeat(event) { return refuseRepeat(action) }
        return verdict(HumanGesture.permit(event, control: control, menuSelection: true), action)
    }

    /// A key held down repeats: Return held on a row must not walk through the preview and send.
    private static func isRepeat(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    private static func refuseRepeat(_ action: String) -> Bool {
        handoffLog.notice("authored-pr \(action, privacy: .public) refused: keyRepeat")
        return false
    }

    private static func verdict(_ v: HumanGestureVerdict, _ action: String) -> Bool {
        switch v {
        case .human: return true
        case .refused(let reason):
            handoffLog.notice("authored-pr \(action, privacy: .public) refused: \(reason.rawValue, privacy: .public)")
            return false
        }
    }
}

// MARK: - Transport

/// What the hand-off needs from the daemon connection. Tests record instead of sending.
protocol AuthoredPrHandoffTransport: AnyObject {
    /// The daemon advertised `authored_prs_notify_v1` and is connected.
    var isAvailable: Bool { get }
    func preview(repo: String, number: Int, target: AuthoredPrPreviewTarget,
                 done: @escaping (AuthoredPrAnswer<AuthoredPrPreviewPayload>) -> Void)
    func notify(repo: String, number: Int, tag: String, digest: String,
                done: @escaping (AuthoredPrAnswer<AuthoredPrDone>) -> Void)
    func startSession(repo: String, number: Int, folder: String, agent: String, digest: String,
                      done: @escaping (AuthoredPrAnswer<AuthoredPrStarted>) -> Void)
    func link(repo: String, number: Int, tag: String?, done: @escaping (AuthoredPrAnswer<AuthoredPrDone>) -> Void)
}

/// The live transport: frames out through the daemon client, answers matched back by request id. A request
/// the daemon does not answer in `timeout` seconds, or that a dropped connection orphans, answers `.unreachable`.
final class AuthoredPrHandoffTransportLive: AuthoredPrHandoffTransport {
    var supported: () -> Bool
    var sendPreview: (ClientAuthoredPrPreviewRequest) -> Void
    var sendNotify: (ClientAuthoredPrNotify) -> Void
    var sendStart: (ClientAuthoredPrStartSession) -> Void
    var sendLink: (ClientAuthoredPrLink) -> Void
    let timeout: TimeInterval

    private var pending: [String: (AuthoredPrAnswerFrame?) -> Void] = [:]

    init(timeout: TimeInterval = 15,
         supported: @escaping () -> Bool,
         sendPreview: @escaping (ClientAuthoredPrPreviewRequest) -> Void,
         sendNotify: @escaping (ClientAuthoredPrNotify) -> Void,
         sendStart: @escaping (ClientAuthoredPrStartSession) -> Void,
         sendLink: @escaping (ClientAuthoredPrLink) -> Void) {
        self.timeout = timeout
        self.supported = supported
        self.sendPreview = sendPreview
        self.sendNotify = sendNotify
        self.sendStart = sendStart
        self.sendLink = sendLink
    }

    var isAvailable: Bool { supported() }

    /// An answer frame from the daemon.
    func deliver(_ frame: AuthoredPrAnswerFrame) {
        guard let done = pending.removeValue(forKey: frame.requestId) else { return }
        done(frame)
    }

    /// The connection dropped: nothing pending can be answered.
    func connectionLost() {
        let all = pending
        pending = [:]
        for done in all.values { done(nil) }
    }

    private func register(_ id: String, _ done: @escaping (AuthoredPrAnswerFrame?) -> Void) {
        pending[id] = done
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let done = self?.pending.removeValue(forKey: id) else { return }
            done(nil)
        }
    }

    func preview(repo: String, number: Int, target: AuthoredPrPreviewTarget,
                 done: @escaping (AuthoredPrAnswer<AuthoredPrPreviewPayload>) -> Void) {
        let id = UUID().uuidString
        register(id) { frame in
            if case .preview(_, let answer)? = frame { done(answer) } else { done(.unreachable) }
        }
        sendPreview(ClientAuthoredPrPreviewRequest(requestId: id, repo: repo, number: number, target: target))
    }

    func notify(repo: String, number: Int, tag: String, digest: String,
                done: @escaping (AuthoredPrAnswer<AuthoredPrDone>) -> Void) {
        let id = UUID().uuidString
        register(id) { frame in
            if case .notify(_, let answer)? = frame { done(answer) } else { done(.unreachable) }
        }
        sendNotify(ClientAuthoredPrNotify(requestId: id, repo: repo, number: number, tag: tag, digest: digest))
    }

    func startSession(repo: String, number: Int, folder: String, agent: String, digest: String,
                      done: @escaping (AuthoredPrAnswer<AuthoredPrStarted>) -> Void) {
        let id = UUID().uuidString
        register(id) { frame in
            if case .startSession(_, let answer)? = frame { done(answer) } else { done(.unreachable) }
        }
        sendStart(ClientAuthoredPrStartSession(requestId: id, repo: repo, number: number,
                                               folder: folder, agent: agent, digest: digest))
    }

    func link(repo: String, number: Int, tag: String?, done: @escaping (AuthoredPrAnswer<AuthoredPrDone>) -> Void) {
        let id = UUID().uuidString
        register(id) { frame in
            if case .link(_, let answer)? = frame { done(answer) } else { done(.unreachable) }
        }
        sendLink(ClientAuthoredPrLink(requestId: id, repo: repo, number: number, tag: tag))
    }
}

// MARK: - Preview

/// One preview: ask the daemon for the message, show it, and on Send put it in the owner's conversation.
final class AuthoredPrPreviewSession {
    enum Phase: Equatable {
        case loading
        case ready
        case sending
        /// The owner focus closed: Send turns into Start a session….
        case ownerClosed
    }
    enum Outcome: Equatable {
        case sent(tag: String)
        case cancelled
        case startSession
    }

    let row: AuthoredPrRowModel
    let tag: String
    private(set) var phase: Phase = .loading
    private(set) var payload: AuthoredPrPreviewPayload?
    /// One line under the message: that the PR changed, or why a send failed.
    private(set) var note: String?
    var onChange: (() -> Void)?
    var onFinish: ((Outcome) -> Void)?

    private let transport: AuthoredPrHandoffTransport
    private let permit: AuthoredPrGesture.Permit
    private var finished = false

    init(row: AuthoredPrRowModel, tag: String, transport: AuthoredPrHandoffTransport, permit: @escaping AuthoredPrGesture.Permit) {
        self.row = row
        self.tag = tag
        self.transport = transport
        self.permit = permit
    }

    /// `Send to Cody (nostromo)`.
    var title: String {
        let who = AuthoredPrsPresentation.firstWord(payload?.targetName ?? row.ownerName ?? "")
        let repo = row.repo.split(separator: "/", maxSplits: 1).last.map(String.init) ?? row.repo
        return "Send to \(who.isEmpty ? "focus" : who) (\(repo))"
    }

    /// The label of the default button.
    var sendTitle: String { phase == .ownerClosed ? "Start a session…" : "Send and switch ⏎" }

    func start() {
        phase = .loading
        onChange?()
        transport.preview(repo: row.repo, number: row.number, target: .focus(tag: tag)) { [weak self] answer in
            self?.previewArrived(answer)
        }
    }

    private func previewArrived(_ answer: AuthoredPrAnswer<AuthoredPrPreviewPayload>) {
        guard !finished else { return }
        switch answer {
        case .ok(let p):
            payload = p
            phase = .ready
        case .failed(let code):
            payload = nil
            if code == "owner_closed" {
                phase = .ownerClosed
            } else {
                note = AuthoredPrsHandoffWords.failure(code: code)
                phase = .ready
            }
        case .unreachable:
            payload = nil
            note = AuthoredPrsHandoffWords.unreachable
            phase = .ready
        }
        onChange?()
    }

    /// Send (or, once the owner closed, go on to Start a session…). Does nothing without a person's gesture.
    func send(event: NSEvent?, control: NSView) {
        guard !finished, permit(event, control, "send") else { return }
        if phase == .ownerClosed {
            finish(.startSession)
            return
        }
        guard phase == .ready, let payload else { return }
        phase = .sending
        note = nil
        onChange?()
        transport.notify(repo: row.repo, number: row.number, tag: tag, digest: payload.digest) { [weak self] answer in
            self?.notifyArrived(answer)
        }
    }

    private func notifyArrived(_ answer: AuthoredPrAnswer<AuthoredPrDone>) {
        guard !finished else { return }
        switch answer {
        case .ok:
            finish(.sent(tag: tag))
            return
        case .failed(let code) where code == "changed":
            // Never send stale text: ask again, and show the new message with a line saying so.
            start()
            note = AuthoredPrsHandoffWords.changed
        case .failed(let code) where code == "owner_closed":
            phase = .ownerClosed
        case .failed(let code):
            note = AuthoredPrsHandoffWords.failure(code: code)
            phase = .ready
        case .unreachable:
            note = AuthoredPrsHandoffWords.unreachable
            phase = .ready
        }
        onChange?()
    }

    /// The open focuses changed: if the owner went, Send becomes Start a session….
    func openFocusesChanged(_ tags: Set<String>) {
        // An empty list is a store that is reloading, not every focus closing at once.
        guard !finished, phase != .ownerClosed, !tags.isEmpty, !tags.contains(tag) else { return }
        phase = .ownerClosed
        onChange?()
    }

    /// Cancel and Escape: nothing is sent.
    func cancel() {
        guard !finished else { return }
        finish(.cancelled)
    }

    private func finish(_ outcome: Outcome) {
        finished = true
        onFinish?(outcome)
    }
}

// MARK: - Picker

/// "Choose focus…": the open focuses to pick from, and the link a choice makes.
final class AuthoredPrPickerSession {
    enum Outcome: Equatable {
        case linked(tag: String)
        case startSession
        case cancelled
    }

    let row: AuthoredPrRowModel
    let entries: [AuthoredPrPickerEntry]
    private(set) var note: String?
    var onChange: (() -> Void)?
    var onFinish: ((Outcome) -> Void)?

    private let transport: AuthoredPrHandoffTransport
    private let permit: AuthoredPrGesture.Permit
    private var finished = false
    private var linking = false

    init(row: AuthoredPrRowModel, entries: [AuthoredPrPickerEntry], transport: AuthoredPrHandoffTransport,
         permit: @escaping AuthoredPrGesture.Permit) {
        self.row = row
        self.entries = entries
        self.transport = transport
        self.permit = permit
    }

    /// Choose entry `index`: a focus is linked to the PR (then previewed), Start a session… opens the sheet.
    func choose(_ index: Int, event: NSEvent?, control: NSView) {
        guard !finished, !linking, entries.indices.contains(index), permit(event, control, "choose") else { return }
        switch entries[index].kind {
        case .startSession:
            finished = true
            onFinish?(.startSession)
        case .focus(let tag):
            linking = true
            transport.link(repo: row.repo, number: row.number, tag: tag) { [weak self] answer in
                guard let self, !self.finished else { return }
                self.linking = false
                switch answer {
                case .ok:
                    self.finished = true
                    self.onFinish?(.linked(tag: tag))
                case .failed(let code):
                    self.note = AuthoredPrsHandoffWords.failure(code: code)
                    self.onChange?()
                case .unreachable:
                    self.note = AuthoredPrsHandoffWords.unreachable
                    self.onChange?()
                }
            }
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        onFinish?(.cancelled)
    }
}

// MARK: - Start a session

/// The sheet's model: a folder, an agent and the message, and one request on Start and send.
final class AuthoredPrStartSessionModel {
    enum Phase: Equatable { case loading, ready, starting }
    enum Outcome: Equatable {
        case started(tag: String)
        case cancelled
    }

    let row: AuthoredPrRowModel
    let agents: [String]
    private(set) var phase: Phase = .loading
    private(set) var payload: AuthoredPrPreviewPayload?
    private(set) var note: String?
    /// Prefilled only from the daemon's suggestion: never guessed.
    var folder: String = "" { didSet { if folder != oldValue { onChange?() } } }
    var agent: String? { didSet { if agent != oldValue { onChange?() } } }
    var onChange: (() -> Void)?
    var onFinish: ((Outcome) -> Void)?
    var directoryExists: (String) -> Bool = { path in
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private let transport: AuthoredPrHandoffTransport
    private let permit: AuthoredPrGesture.Permit
    private var finished = false

    init(row: AuthoredPrRowModel, agents: [String], transport: AuthoredPrHandoffTransport,
         permit: @escaping AuthoredPrGesture.Permit) {
        self.row = row
        self.agents = agents
        self.transport = transport
        self.permit = permit
        agent = Self.defaultAgent(in: agents)
    }

    /// `claudia` when it is there (as the New Focus sheet does), else the first.
    static func defaultAgent(in agents: [String]) -> String? {
        agents.contains("claudia") ? "claudia" : agents.first
    }

    /// Start is on only with a message, an agent and a folder that exists.
    var canStart: Bool {
        phase == .ready && payload != nil && agent != nil
            && folder.hasPrefix("/") && directoryExists(folder)
    }

    func load() {
        phase = .loading
        onChange?()
        transport.preview(repo: row.repo, number: row.number, target: .newSession) { [weak self] answer in
            guard let self, !self.finished else { return }
            switch answer {
            case .ok(let p):
                let first = self.payload == nil
                self.payload = p
                if first {
                    if let suggested = p.suggestedFolder { self.folder = suggested }
                    if let a = p.suggestedAgent, self.agents.contains(a) { self.agent = a }
                }
                self.phase = .ready
            case .failed(let code):
                self.note = AuthoredPrsHandoffWords.failure(code: code)
                self.phase = .ready
            case .unreachable:
                self.note = AuthoredPrsHandoffWords.unreachable
                self.phase = .ready
            }
            self.onChange?()
        }
    }

    func start(event: NSEvent?, control: NSView) {
        guard !finished, canStart, let payload, let agent, permit(event, control, "start") else { return }
        phase = .starting
        note = nil
        onChange?()
        transport.startSession(repo: row.repo, number: row.number, folder: folder, agent: agent,
                               digest: payload.digest) { [weak self] answer in
            guard let self, !self.finished else { return }
            switch answer {
            case .ok(let started):
                self.finished = true
                self.onFinish?(.started(tag: started.tag))
                return
            case .failed(let code) where code == "changed":
                self.load()
                self.note = AuthoredPrsHandoffWords.changed
            case .failed(let code):
                self.note = AuthoredPrsHandoffWords.failure(code: code)
                self.phase = .ready
            case .unreachable:
                self.note = AuthoredPrsHandoffWords.unreachable
                self.phase = .ready
            }
            self.onChange?()
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        onFinish?(.cancelled)
    }
}

// MARK: - Controller

/// What is on screen for a hand-off: a preview, a picker or the Start a session sheet.
enum AuthoredPrPresented {
    case preview(AuthoredPrPreviewSession)
    case picker(AuthoredPrPickerSession)
    case start(AuthoredPrStartSessionModel)
}

/// Opens the preview, the picker or the sheet for a row, and carries the hand-off to the focus afterwards.
final class AuthoredPrHandoff {
    let transport: AuthoredPrHandoffTransport
    let presenter: FocusPresenter
    var permit: AuthoredPrGesture.Permit = AuthoredPrGesture.live
    var permitMenu: AuthoredPrGesture.Permit = AuthoredPrGesture.liveMenu
    /// The open focuses the picker may offer.
    var openFocuses: () -> [AuthoredPrPickerFocus]
    /// The agents Start a session… offers.
    var agents: () -> [String] = { CreateFocusSheet.discoverAgents() }
    /// The tags of the open focuses, each time they change (the preview watches its owner).
    var openFocusTags: AnyPublisher<Set<String>, Never>
    /// Shows `presented` anchored at the view; `dismiss` takes it down. The default is the real popover and sheet.
    var present: (AuthoredPrPresented, NSView) -> Void = { AuthoredPrHandoffUI.show($0, from: $1) }
    var dismiss: () -> Void = { AuthoredPrHandoffUI.dismiss() }

    private(set) var presented: AuthoredPrPresented?
    private var anchor: NSView?
    private var focusWatch: AnyCancellable?

    init(transport: AuthoredPrHandoffTransport, presenter: FocusPresenter,
         openFocuses: @escaping () -> [AuthoredPrPickerFocus],
         openFocusTags: AnyPublisher<Set<String>, Never>) {
        self.transport = transport
        self.presenter = presenter
        self.openFocuses = openFocuses
        self.openFocusTags = openFocusTags
    }

    /// The button, or Return on a row. Opens the preview, the picker or the sheet; it never sends anything.
    func activate(_ model: AuthoredPrRowModel, anchor: NSView, event: NSEvent?, control: NSView) {
        guard transport.isAvailable, let button = model.tellButton, permit(event, control, "activate") else { return }
        switch button.action {
        case .tell(let tag): openPreview(model, tag: tag, anchor: anchor)
        case .choose: openPicker(model, anchor: anchor)
        case .start: openStart(model, anchor: anchor)
        }
    }

    /// Unlink (context menu): the link is removed; the next snapshot shows it.
    func unlink(_ model: AuthoredPrRowModel, event: NSEvent?, control: NSView) {
        guard transport.isAvailable, model.ownerKind == .linked, permitMenu(event, control, "unlink") else { return }
        transport.link(repo: model.repo, number: model.number, tag: nil) { _ in }
    }

    // MARK: Opening

    private func show(_ item: AuthoredPrPresented, anchor: NSView) {
        close()
        presented = item
        self.anchor = anchor
        present(item, anchor)
    }

    private func close() {
        focusWatch = nil
        // A session taken down without finishing must not call back into whatever replaced it.
        switch presented {
        case .preview(let s)?: s.onFinish = nil; s.onChange = nil
        case .picker(let s)?: s.onFinish = nil; s.onChange = nil
        case .start(let s)?: s.onFinish = nil; s.onChange = nil
        case nil: break
        }
        if presented != nil { dismiss() }
        presented = nil
    }

    private func openPreview(_ model: AuthoredPrRowModel, tag: String, anchor: NSView) {
        let session = AuthoredPrPreviewSession(row: model, tag: tag, transport: transport, permit: permit)
        session.onFinish = { [weak self, weak anchor] outcome in
            guard let self else { return }
            let origin = anchor?.window
            self.close()
            switch outcome {
            case .sent(let tag): self.presenter.show(tag: tag, from: origin)
            case .cancelled: break
            case .startSession: if let anchor { self.openStart(model, anchor: anchor) }
            }
        }
        show(.preview(session), anchor: anchor)
        // After `show`, which takes down whatever was up (and its watch) first.
        focusWatch = openFocusTags.sink { [weak session] tags in session?.openFocusesChanged(tags) }
        session.start()
    }

    private func openPicker(_ model: AuthoredPrRowModel, anchor: NSView) {
        guard let pr = pickerSource(model) else { return }
        let entries = AuthoredPrsPicker.entries(for: pr, openFocuses: openFocuses())
        let session = AuthoredPrPickerSession(row: model, entries: entries, transport: transport, permit: permit)
        session.onFinish = { [weak self, weak anchor] outcome in
            guard let self else { return }
            guard let anchor else { self.close(); return }
            self.close()
            switch outcome {
            case .linked(let tag):
                // The link is made; the preview for that focus follows.
                self.openPreview(model, tag: tag, anchor: anchor)
            case .startSession: self.openStart(model, anchor: anchor)
            case .cancelled: break
            }
        }
        show(.picker(session), anchor: anchor)
    }

    /// The picker only needs the owner's kind and candidates, which the row model carries as text; rebuild
    /// the minimal `AuthoredPr` the entries are derived from.
    private func pickerSource(_ model: AuthoredPrRowModel) -> AuthoredPr? {
        AuthoredPr(repo: model.repo, number: model.number, title: model.title,
                   owner: AuthoredPrOwner(kind: model.ownerKind, tag: model.ownerTag, name: model.ownerName,
                                          candidates: model.ownerCandidates))
    }

    private func openStart(_ model: AuthoredPrRowModel, anchor: NSView) {
        let sheet = AuthoredPrStartSessionModel(row: model, agents: agents(), transport: transport, permit: permit)
        sheet.onFinish = { [weak self, weak anchor] outcome in
            guard let self else { return }
            let origin = anchor?.window
            self.close()
            if case .started(let tag) = outcome { self.presenter.show(tag: tag, from: origin) }
        }
        show(.start(sheet), anchor: anchor)
        sheet.load()
    }
}
